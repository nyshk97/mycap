#!/bin/bash
# ビルド済みの .app を /Applications に置いて起動し直す。
# 使い方: scripts/install-app.sh Debug|Release
#
# 常駐アプリは旧プロセスが残っていると open しても新ビルドが起動しない（偽 pass する）ので、
# 終了を待ってから差し替える。dev も /Applications の固定パスに置くのは、TCC（画面収録）の
# 許可をパスと署名で安定させるため。
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:?Debug|Release}"
case "$CONFIG" in
  Debug) NAME="Capit Dev" ;;
  Release) NAME="Capit" ;;
  *) echo "NG: Debug か Release を指定する" >&2; exit 1 ;;
esac
SRC="build/Build/Products/$CONFIG/$NAME.app"
DEST="/Applications/$NAME.app"
[ -d "$SRC" ] || { echo "NG: $SRC が無い（先にビルドする）" >&2; exit 1; }

if pgrep -x "$NAME" > /dev/null; then
  pkill -x "$NAME" || true
  for _ in $(seq 1 50); do
    pgrep -x "$NAME" > /dev/null || break
    sleep 0.1
  done
  if pgrep -x "$NAME" > /dev/null; then
    pkill -9 -x "$NAME" || true
    sleep 0.5
  fi
fi

/bin/rm -rf "$DEST"
ditto "$SRC" "$DEST"
open -g "$DEST"

for _ in $(seq 1 50); do
  pid=$(pgrep -x "$NAME" || true)
  [ -n "$pid" ] && break
  sleep 0.1
done
[ -n "${pid:-}" ] || { echo "NG: $NAME が起動しない" >&2; exit 1; }
echo "OK: $DEST を起動した（pid ${pid}）"
if [ -n "${CLAUDECODE:-}" ]; then
  echo "注意: Claude Code のセッションのビルドは ad-hoc 署名なので、画面収録の許可が外れる。許可が要る確認はユーザーの Terminal で mise run run する" >&2
fi
