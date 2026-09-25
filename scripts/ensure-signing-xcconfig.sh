#!/bin/bash
# 署名 xcconfig が無ければ ad-hoc 署名の xcconfig を置く（keychain には触らない）。
#
# 本来の署名 ID は scripts/gen-signing-xcconfig.sh（mise run signing）が keychain から解決して書く。
# ただし会社貸与 PC では Claude Code のセッションから keychain に触れないため、AI の検証ビルドは
# ad-hoc で通す。ad-hoc はリビルドごとに画面収録の許可が外れる（撮るたびに許可のダイアログが
# 出る）ので、常用の dev ビルドは mise run signing を一度叩いてから作る。
set -euo pipefail
cd "$(dirname "$0")/.."
header="// scripts/ensure-signing-xcconfig.sh が生成（ad-hoc。mise run signing で証明書に置き換わる）"
for f in signing-debug.local.xcconfig signing-release.local.xcconfig; do
  if [ ! -f "$f" ]; then
    printf '%s\nCODE_SIGN_IDENTITY = -\n' "$header" > "$f"
    echo "signing: $f が無いので ad-hoc で作った（mise run signing で証明書署名に切り替わる）" >&2
  fi
done
