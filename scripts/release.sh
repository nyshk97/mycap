#!/bin/bash
# mycap リリーススクリプト
# 使い方: ./scripts/release.sh [patch|minor|major|<x.y.z>]   （省略時は patch）
#
# 0. preflight.sh（main / clean / push 済み / タグと Release が未作成 / 資格情報 / CHANGELOG / 画面ロック）
# 1. project.yml の MARKETING_VERSION を bump し、docs/CHANGELOG.md の [Unreleased] を
#    [<version>] - <date> に切り出して、同じ commit にする
# 2. make-release-zip.sh で Release ビルド + 配布要件の再署名 + zip 化
# 3. notarize.sh で notarize + staple
# 4. zip に Sparkle の EdDSA 署名を付けて dist/appcast.xml を生成（CHANGELOG を <description> に）
# 5. bump commit を main に push
# 6. GitHub Release（v<version>）を作成し zip と appcast.xml を添付（ノートは CHANGELOG から）
# 7. nyshk97/homebrew-tap の Casks/mycap.rb を更新し、ローカルの tap を同期
#
# notarize（失敗しやすい工程）を push より前に置く。bump はビルド前にローカルで commit する。
# push までに失敗したら trap がその commit を巻き戻すので、remote には何も反映されず
# 作業ツリーも実行前の状態に戻る。条件は submit の数分間に画面がロックされないこと（preflight でロック中なら止める）。
# keychain（署名 ID・notarize の資格情報・Sparkle の秘密鍵）に触るので、会社貸与 PC では
# Claude Code のセッションから叩かず自分の Terminal で叩く（個人 PC ならセッションから叩いてよい）。
set -euo pipefail
cd "$(dirname "$0")/.."
REPO_ROOT="$(pwd)"

APP_NAME="mycap"
GITHUB_REPO="nyshk97/mycap"
TAP_REPO="nyshk97/homebrew-tap"
CASK_TOKEN="mycap"
CASK_PATH="Casks/${CASK_TOKEN}.rb"
# Sparkle の鍵は keychain の account "mycap"（アプリごとに分ける）。SUPublicEDKey と対になっているので変えない。
SPARKLE_ACCOUNT="${SPARKLE_ACCOUNT:-mycap}"
SIGN_UPDATE="$REPO_ROOT/build/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update"
CHANGELOG_PY="$REPO_ROOT/scripts/changelog.py"
APPCAST="$REPO_ROOT/dist/appcast.xml"

# ===== バージョン計算 =====
CURRENT_VERSION=$(grep -m1 'MARKETING_VERSION:' project.yml | sed 's/.*MARKETING_VERSION:[[:space:]]*//' | tr -d '"' | tr -d ' ')
[ -n "$CURRENT_VERSION" ] || { echo "NG: project.yml から MARKETING_VERSION を取れない"; exit 1; }
BUMP="${1:-patch}"
IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT_VERSION"
case "$BUMP" in
  major) MAJOR=$((MAJOR + 1)); MINOR=0; PATCH=0 ;;
  minor) MINOR=$((MINOR + 1)); PATCH=0 ;;
  patch) PATCH=$((PATCH + 1)) ;;
  [0-9]*.[0-9]*.[0-9]*) IFS='.' read -r MAJOR MINOR PATCH <<< "$BUMP" ;;
  *) echo "NG: 不正なバージョン指定: ${BUMP}（patch|minor|major|x.y.z）"; exit 1 ;;
esac
NEW_VERSION="$MAJOR.$MINOR.$PATCH"
TAG="v$NEW_VERSION"
DIST_ZIP="$REPO_ROOT/dist/mycap-$NEW_VERSION.zip"
echo "現在のバージョン: ${CURRENT_VERSION} → 新しいバージョン: ${NEW_VERSION}"

# ===== preflight =====
RELEASE_VERSION="$NEW_VERSION" bash scripts/preflight.sh

# ===== バージョン更新 + CHANGELOG 切り出し（ローカル commit。push は notarize 後）=====
sed -i '' "s/MARKETING_VERSION:.*/MARKETING_VERSION: $NEW_VERSION/" project.yml
python3 "$CHANGELOG_PY" release "$NEW_VERSION" "$(date +%Y-%m-%d)"
git add project.yml docs/CHANGELOG.md
git commit -q -m "chore: bump version to $TAG"
BUMP_PUSHED=0
rollback_bump() {
  if [ "$BUMP_PUSHED" -eq 0 ]; then
    echo "↩️  失敗したので bump commit を巻き戻します（remote は未変更）"
    git reset -q --hard HEAD~1
  fi
}
trap 'rollback_bump' ERR

# ===== ビルド + 署名 + notarize =====
bash scripts/make-release-zip.sh
bash scripts/notarize.sh
[ -f "$DIST_ZIP" ] || { echo "NG: 配布 zip が見つからない: $DIST_ZIP"; exit 1; }
SHA256=$(shasum -a 256 "$DIST_ZIP" | awk '{print $1}')

# ===== Sparkle: EdDSA 署名 + appcast =====
[ -x "$SIGN_UPDATE" ] || { echo "NG: sign_update が見つからない: $SIGN_UPDATE"; exit 1; }
ED_ATTRS=$("$SIGN_UPDATE" --account "$SPARKLE_ACCOUNT" "$DIST_ZIP")   # sparkle:edSignature="..." length="..."
case "$ED_ATTRS" in
  *sparkle:edSignature=*) ;;
  *) echo "NG: sign_update の出力が想定外: $ED_ATTRS"; exit 1 ;;
esac
RELEASE_NOTES_MD="$REPO_ROOT/dist/release-notes-$NEW_VERSION.md"
SPARKLE_DESC_HTML="$REPO_ROOT/dist/sparkle-description-$NEW_VERSION.html"
python3 "$CHANGELOG_PY" notes "$NEW_VERSION" "$RELEASE_NOTES_MD" "$SPARKLE_DESC_HTML"
PUBDATE=$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")
DOWNLOAD_URL="https://github.com/$GITHUB_REPO/releases/download/$TAG/mycap-$NEW_VERSION.zip"
RELEASE_URL="https://github.com/$GITHUB_REPO/releases/tag/$TAG"
# 1 item だけでよい: feed は releases/latest/download/appcast.xml で常に最新 Release の物を指す。
# CFBundleVersion = MARKETING_VERSION なので sparkle:version もそれ。
cat > "$APPCAST" <<APPCAST_EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>$APP_NAME</title>
    <item>
      <title>$TAG</title>
      <pubDate>$PUBDATE</pubDate>
      <sparkle:version>$NEW_VERSION</sparkle:version>
      <sparkle:shortVersionString>$NEW_VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>$RELEASE_URL</sparkle:fullReleaseNotesLink>
      <description><![CDATA[
$(cat "$SPARKLE_DESC_HTML")
]]></description>
      <enclosure url="$DOWNLOAD_URL" $ED_ATTRS type="application/octet-stream"/>
    </item>
  </channel>
</rss>
APPCAST_EOF
xmllint --noout "$APPCAST"

# ===== push → Release（タグは gh が作る）=====
git push origin main
BUMP_PUSHED=1
trap - ERR

echo "🚀 GitHub Release を作成中..."
gh release create "$TAG" "$DIST_ZIP" "$APPCAST" \
  --repo "$GITHUB_REPO" \
  --title "$APP_NAME $TAG" \
  --notes-file "$RELEASE_NOTES_MD"

# ===== Cask 更新（nyshk97/homebrew-tap）=====
echo "🍺 Cask $CASK_PATH を更新中..."
CASK_CONTENT="$(cat <<CASK
cask "$CASK_TOKEN" do
  version "$NEW_VERSION"
  sha256 "$SHA256"

  url "https://github.com/$GITHUB_REPO/releases/download/v#{version}/mycap-#{version}.zip"
  name "$APP_NAME"
  desc "Personal screenshot tool: capture, OCR, pin and screen recording"
  homepage "https://github.com/$GITHUB_REPO"

  auto_updates true
  depends_on macos: :tahoe

  app "mycap.app"
end
CASK
)"
ENCODED=$(printf '%s' "$CASK_CONTENT" | base64)
EXISTING_SHA=$(gh api "repos/$TAP_REPO/contents/$CASK_PATH" --jq '.sha' 2>/dev/null || true)
if [ -n "$EXISTING_SHA" ]; then
  gh api "repos/$TAP_REPO/contents/$CASK_PATH" --method PUT \
    --field message="chore: $CASK_TOKEN $NEW_VERSION" --field content="$ENCODED" --field sha="$EXISTING_SHA" --silent
else
  gh api "repos/$TAP_REPO/contents/$CASK_PATH" --method PUT \
    --field message="feat: add $CASK_TOKEN $NEW_VERSION" --field content="$ENCODED" --silent
fi
# brew のローカル tap クローンは自動更新されないので pull しておく
TAP_DIR=$(brew --repository "$TAP_REPO" 2>/dev/null || true)
if [ -n "$TAP_DIR" ] && [ -d "$TAP_DIR/.git" ]; then
  git -C "$TAP_DIR" pull --ff-only --quiet origin main || true
fi

echo ""
echo "✅ リリース完了: $TAG"
echo "   release: $RELEASE_URL"
echo "   sha256 : $SHA256"
echo "   cask   : $TAP_REPO $CASK_PATH"
