#!/bin/bash
# dist/mycap-<version>.zip を notarize して staple 済みの zip に差し替える
#
# 資格情報は `xcrun notarytool store-credentials <プロファイル名>` で作った keychain
# プロファイル（既定 "nyshk97-notary"。自作 Mac アプリ全体で共通）を使う。中身は
# App Store Connect の API キーで、登録は 1 コマンドで済む:
#   xcrun notarytool store-credentials nyshk97-notary \
#     --key ~/Library/CloudStorage/Dropbox/secrets/AuthKey_M4FG2B8JFX.p8 \
#     --key-id M4FG2B8JFX --issuer 024fc873-10f9-49a4-8d6f-20fb5c7bd522
#
# 注: 資格情報は data-protection keychain にあり、画面ロック中だけ「プロファイルが無い」
#     ように見える（Claude Code の Bash からでも解除中なら通る。preflight.sh でロック中は止める）。
set -euo pipefail
cd "$(dirname "$0")/.."

PROFILE="${NOTARY_PROFILE:-nyshk97-notary}"
APP="build/Build/Products/Release/mycap.app"
[ -d "$APP" ] || { echo "NG: $APP がない（先に mise run release:zip）"; exit 1; }
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
ZIP="dist/mycap-$VERSION.zip"
[ -f "$ZIP" ] || { echo "NG: $ZIP がない（先に mise run release:zip）"; exit 1; }

xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait

# staple は .app に対して行う。zip の中身を展開して貼り、貼った方を再 zip する
# （release.sh は zip をそのまま配布するため、zip 側に入れる必要がある）。
STAPLE_DIR=$(mktemp -d)
ditto -x -k "$ZIP" "$STAPLE_DIR"
xcrun stapler staple "$STAPLE_DIR/mycap.app"

assess=$(spctl --assess --type execute -vv "$STAPLE_DIR/mycap.app" 2>&1)
case "$assess" in
    *"Notarized Developer ID"*) ;;
    *) echo "NG: Gatekeeper 評価が通らない: $assess"; exit 1 ;;
esac

/bin/rm -f "$ZIP" 2>/dev/null || true
ditto -c -k --sequesterRsrc --keepParent "$STAPLE_DIR/mycap.app" "$ZIP"
/bin/rm -rf "$STAPLE_DIR" 2>/dev/null || true

echo "OK: ${ZIP}（notarize + staple 済み。$(echo "$assess" | grep '^source=')）"
