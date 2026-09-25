#!/bin/bash
# リリース前チェック。壊す前に（ビルドと Apple への submit の前に）全部検査する。
#
# release.sh の最初に呼ぶ（RELEASE_VERSION にこれから付けるバージョンが入る）。単体で
# `mise run release:preflight` したときは project.yml の現在値で検査する。
set -euo pipefail
cd "$(dirname "$0")/.."

GITHUB_REPO="nyshk97/mycap"
TEAM_ID="VYDUR99LAM"
NOTARY_PROFILE="${NOTARY_PROFILE:-nyshk97-notary}"
SPARKLE_ACCOUNT="${SPARKLE_ACCOUNT:-mycap}"
VERSION="${RELEASE_VERSION:-$(grep -m1 'MARKETING_VERSION:' project.yml | sed 's/.*MARKETING_VERSION:[[:space:]]*//' | tr -d '"' | tr -d ' ')}"
TAG="v$VERSION"
[ -n "$VERSION" ] || { echo "NG: project.yml から MARKETING_VERSION を取れない"; exit 1; }

echo "preflight: $TAG をリリースする前提で検査する"

if ! gh auth status > /dev/null 2>&1; then
    echo "NG: gh が未認証（gh auth login）"; exit 1
fi

# 比較の前にリモートを取り込む。古い追跡参照と比べると「push 済みのつもり」を見逃す。
git fetch origin --tags --quiet

BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [ "$BRANCH" != "main" ]; then
    echo "NG: カレントブランチが main でない（${BRANCH}）"; exit 1
fi

# 未追跡ファイルも含めて見る。ビルド定義に追加済みの新規ソースが未追跡だと、
# 配布物には入るのにタグの commit には無いという乖離になる。
DIRTY=$(git status --porcelain)
if [ -n "$DIRTY" ]; then
    echo "NG: 作業ツリーがクリーンでない（未追跡ファイルも対象）:"
    echo "$DIRTY"
    exit 1
fi

LOCAL_HEAD=$(git rev-parse HEAD)
REMOTE_HEAD=$(git rev-parse origin/main)
if [ "$LOCAL_HEAD" != "$REMOTE_HEAD" ]; then
    echo "NG: HEAD が origin/main と一致しない（push 忘れ / pull 忘れ）"
    echo "    local:  $LOCAL_HEAD"
    echo "    origin: $REMOTE_HEAD"
    exit 1
fi

if git rev-parse -q --verify "refs/tags/$TAG" > /dev/null; then
    echo "NG: タグ $TAG が既にある（別のバージョンを指定する）"; exit 1
fi

# gh は「repo が無い」ときも Release 照会と同じ "release not found" を返すため、先に repo の
# 到達を確認しておく。これで後段の "release not found" が「本当に Release が無い」に確定する。
if ! repo_out=$(gh repo view "$GITHUB_REPO" --json name 2>&1); then
    echo "NG: $GITHUB_REPO を参照できない（通信エラー / 権限 / repo 名の誤り）:"
    echo "    $repo_out"
    exit 1
fi

# gh の失敗は「Release が無い」と「通信エラー」を区別する。握りつぶすと既存 Release を
# 見逃して進み、公開済みバージョンを上書きしようとする。
if release_out=$(gh release view "$TAG" --repo "$GITHUB_REPO" 2>&1); then
    echo "NG: GitHub Release $TAG が既にある（別のバージョンを指定する）"; exit 1
elif [ "$release_out" != "release not found" ]; then
    echo "NG: GitHub Release の確認に失敗した（通信エラー等。無いとは断定できない）:"
    echo "    $release_out"
    exit 1
fi

# SUPublicEDKey が未設定のままだと、配ったアプリが更新を検証できない（Sparkle も起動しない）
if grep -q '__SPARKLE_PUBLIC_KEY_NOT_SET__' project.yml; then
    echo "NG: project.yml の SUPublicEDKey が未設定"
    echo "    build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys --account mycap の公開鍵を書く"
    exit 1
fi

# リリースノートは docs/CHANGELOG.md の [Unreleased] からしか作らない。空なら止める
python3 scripts/changelog.py check

# 署名証明書・notarize の資格情報・Sparkle の鍵は keychain にあり、開発機を移すと欠ける。
# 5 分のビルドを終えてから落ちないよう先に見る
IDENTITIES=$(security find-identity -v -p codesigning 2>/dev/null || true)
case "$IDENTITIES" in
    *"Developer ID Application"*"($TEAM_ID)"*) ;;
    *) echo "NG: Developer ID Application 証明書（${TEAM_ID}）が keychain にない"
       echo "    Xcode → Settings → Accounts → Manage Certificates から取得する"; exit 1 ;;
esac
# 画面ロック中は notarytool の資格情報（data-protection keychain）が読めない
CONSOLE_LOCKED=$(ioreg -n Root -d1 -a 2>/dev/null | plutil -extract IOConsoleLocked raw -o - - 2>/dev/null || true)
if [ "$CONSOLE_LOCKED" = "true" ]; then
    echo "NG: 画面がロックされている。notarize の資格情報が読めないので解除してから実行する"; exit 1
fi
if ! notary_out=$(xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" 2>&1); then
    echo "NG: notarize の keychain プロファイル '${NOTARY_PROFILE}' が使えない:"
    echo "$notary_out" | head -3
    echo "    作成: xcrun notarytool store-credentials $NOTARY_PROFILE \\"
    echo "            --key ~/Library/CloudStorage/Dropbox/secrets/AuthKey_M4FG2B8JFX.p8 \\"
    echo "            --key-id M4FG2B8JFX --issuer 024fc873-10f9-49a4-8d6f-20fb5c7bd522"
    exit 1
fi
if ! security find-generic-password -s "https://sparkle-project.org" -a "$SPARKLE_ACCOUNT" > /dev/null 2>&1; then
    echo "NG: Sparkle の EdDSA 秘密鍵（keychain account '${SPARKLE_ACCOUNT}'）が無い"
    echo "    復元: build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys --account mycap -f ~/Library/CloudStorage/Dropbox/secrets/sparkle-ed25519-mycap-private.key"
    exit 1
fi

echo "preflight: OK（$TAG は未リリース。main / clean / push 済み / CHANGELOG あり / 資格情報あり）"
