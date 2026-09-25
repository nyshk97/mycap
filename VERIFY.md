# 動作確認手順

## ビルドとテスト

```bash
mise run build          # Debug（mycap Dev）。署名 xcconfig が無ければ ad-hoc で通る
mise run build-release  # Release（mycap）
mise run test           # Sources/Core の純粋関数（ファイル名の規則・サムネイルの大きさと積み方・OCR の行の組み立て・ピンの大きさ）
mise run run            # /Applications/mycap Dev.app に置いて起動し直す（旧プロセスの終了を待つ）
```

dev と常用で Info.plist が分かれていることの確認（dev に `SUFeedURL` の値が**無い**こと）:

```bash
for c in Debug Release; do n=$([ $c = Debug ] && echo "mycap Dev" || echo mycap)
  p="build/Build/Products/$c/$n.app/Contents/Info.plist"
  for k in CFBundleIdentifier CFBundleDisplayName CFBundleVersion SUFeedURL; do
    printf '%s %s=' $c $k; /usr/libexec/PlistBuddy -c "Print :$k" "$p"; done; done
```

ログは `~/Library/Logs/mycap/mycap-dev.log`（常用版は `mycap.log`）。先頭の語がイベント名:
`launch` / `hotkey.registered` / `hotkey.register_failed` / `hotkey.not_implemented` / `menu.installed` /
`tcc.preflight granted=… when=launch|before_capture|after_capture|hook` /
`capture.started` / `capture.finished` / `capture.cancelled` / `capture.{region,full,ingest}.saved` / `capture.skipped` / `capture.save_failed` /
`clipboard.copied` / `thumbnail.added` / `thumbnail.closed reason=button|dragged_out|trashed|overflow|pinned` / `thumbnail.closed_all` / `thumbnail.drag_ended` / `thumbnail.screens_changed` / `toast.shown` /
`ocr.done source=hotkey|thumbnail|pin|hook chars= lines= ms=` / `ocr.failed` / `pin.opened` / `pin.close_requested reason=esc|double_click|menu` / `pin.closed` / `pin.opacity` /
`cleanshot.running`（常用版のみ）/ `launch.forward_to_running`。

## 検証フック（dev 版のみ・フォーカスを奪わない）

常駐中の dev に引数を渡す（2 個目のプロセスは引数を既存インスタンスへ転送して終了する）。
**保存先は `MYCAP_SAVE_DIR` で差し替えて起動し直してから撃つ**（`~/Downloads` を汚さない）。フックはクリップボードに書かない。

```bash
S=<scratchpad>; mkdir -p $S/save $S/fx
# fixture（大きさの違う画像。72dpi なのでピクセル = ポイント）
I=Sources/Assets.xcassets/AppIcon.appiconset/icon_1024.png
sips -z 540 960 $I --out $S/fx/wide.png; sips -z 900 300 $I --out $S/fx/tall.png
sips -z 20 40 $I --out $S/fx/tiny.png;  sips -z 50 3000 $I --out $S/fx/strip.png
pkill -x "mycap Dev"; while pgrep -x "mycap Dev" >/dev/null; do sleep 0.2; done
open -g --env MYCAP_SAVE_DIR=$S/save "/Applications/mycap Dev.app"
B=(open -n -g "/Applications/mycap Dev.app" --args)
"${B[@]}" --ingest $S/fx/wide.png --ingest $S/fx/tall.png --ingest $S/fx/tiny.png --ingest $S/fx/strip.png
"${B[@]}" --dump-thumbs          # hook.thumbs に最新が先頭で name / screen / frame / hovered
"${B[@]}" --hover --snapshot $S/thumb-hover.png --unhover   # ホバー時のボタンの見た目
"${B[@]}" --full                 # 全画面（選択 UI が出ないのでフック可。許可が無ければトーストで止まる）
"${B[@]}" --close-all
# OCR（期待値は Tests/Fixtures/ocr-ja-en.txt。fixture は swift scripts/make_ocr_fixture.swift で作り直せる）
"${B[@]}" --ocr "$PWD/Tests/Fixtures/ocr-ja-en.png"      # hook.ocr text=…（改行は ⏎）
# ピン（マウスのある画面の中央に実寸。--zoom-pin は中心を固定して倍率を掛ける。上限 4 倍・下限 0.1 倍）
"${B[@]}" --pin "$PWD/Tests/Fixtures/ocr-ja-en.png" --dump-pins --zoom-pin 2 --dump-pins --close-pins
```

- 位置の突き合わせは、画面の frame / visibleFrame を `swift` の小さなスクリプトで出す（`NSScreen.screens` の `NSScreenNumber` と `visibleFrame`）。最新の frame の右端 = visibleFrame.maxX − 16、下端 = visibleFrame.minY + 16 になる
- 同じ秒に複数枚入れると `_2` `_3` が付く
- `--snapshot` はプロセス内描画なので画面収録の許可は要らない。角丸・影は写らない（レイアウトとボタンの確認用）
- `--full` を許可なしで撃つと `CGRequestScreenCaptureAccess()` が OS のダイアログを出すことがある（ユーザーの画面に出る）
- `--tcc`: 許可の状態をログに出すだけ

## 画面収録の許可（TCC）

- 許可の状態は `tcc.preflight` の行で見る。起動時・撮影の前後に必ず出る
- **Claude Code のセッションからのビルドは常に ad-hoc**（`CLAUDECODE` を見て `CODE_SIGN_IDENTITY=-` を渡す）で、リビルドごとに許可が外れる。許可が続くかを見るのは、ユーザーが自分の Terminal で `mise run signing` → `mise run run` したビルドで
- 許可が署名で安定しているかは、2 回のビルドで designated requirement が一致するかで見る:
  `codesign -dr - "/Applications/mycap Dev.app"`（ハッシュ直指定でなく、証明書の identifier と Team で書かれていれば安定）
- 許可を付け直すときは `tccutil reset ScreenCapture io.github.nyshk97.mycap.dev`
- 撮影（`screencapture -i`）は OS の範囲選択 UI がユーザーの画面に出るため、AI からは撃たない。人間が ⌃⌥⌘4 を押し、AI はログの `capture.*` と `tcc.preflight` で確かめる

## メニューバーのアイコン

`StatusIcon.swift` をそのまま `swiftc` で小さな描画プログラムと一緒にコンパイルし、PNG に書き出して見る（アプリを起動せずに確認できる）。
