#!/bin/bash
# 署名証明書のハッシュはマシンごとに異なるため、project.yml に直書きせず
# keychain から検出して gitignore 対象の *.local.xcconfig に書き出す。
# ハッシュ固定の目的（TCC 権限の安定）は各マシン内で保たれる。
#
# dev（Debug）も Developer ID Application で署名する。Apple Development は 1 年で失効し、
# 再発行で CN が変わると画面収録の許可が外れるため。
#
# keychain に触るので、会社貸与 PC では Claude Code のセッションから実行しない（自分の Terminal で叩く）。
set -euo pipefail
cd "$(dirname "$0")/.."

# 配布用の Developer ID は Team ID で絞る（keychain に他 Team の証明書があっても誤爆しない）。
# make-release-zip.sh の再署名も同じ Team で引くので、両者の解決先が食い違わない。
RELEASE_TEAM_ID="VYDUR99LAM"
ids=$(security find-identity -v -p codesigning)
release_hash=$(echo "$ids" | awk "/\"Developer ID Application.*\\($RELEASE_TEAM_ID\\)\"/ {print \$2; exit}")
debug_hash=$release_hash

# 同一内容の上書きをしない（xcconfig の mtime 更新で全リビルドが走るのを防ぐ）
write_if_changed() {
  local path=$1 content=$2
  if [ ! -f "$path" ] || [ "$(cat "$path")" != "$content" ]; then
    printf '%s\n' "$content" > "$path"
    echo "signing: $path を更新した"
  fi
}

header="// scripts/gen-signing-xcconfig.sh が生成（マシン固有・コミットしない）"

if [ -n "$debug_hash" ]; then
  write_if_changed signing-debug.local.xcconfig "$header
CODE_SIGN_IDENTITY = $debug_hash"
else
  write_if_changed signing-debug.local.xcconfig "$header
// Developer ID Application 証明書が keychain に無いため ad-hoc
CODE_SIGN_IDENTITY = -"
  echo "signing: 警告: Developer ID Application 証明書が見つからない（Debug は ad-hoc で署名する）" >&2
fi

if [ -n "$release_hash" ]; then
  write_if_changed signing-release.local.xcconfig "$header
CODE_SIGN_IDENTITY = $release_hash"
else
  write_if_changed signing-release.local.xcconfig "$header
// Developer ID Application 証明書が keychain に無いため未設定"
  echo "signing: 警告: Developer ID Application 証明書が見つからない（Release ビルドは署名で失敗する）" >&2
fi
