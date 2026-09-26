# 動作確認手順

## ビルドとテスト

```bash
mise run build          # Debug（mycap Dev）。署名 xcconfig が無ければ ad-hoc で通る
mise run build-release  # Release（mycap）
mise run test           # Sources/Core の純粋関数（ファイル名の規則・サムネイルの大きさと積み方・OCR の行の組み立て・ピンの大きさ・注釈（矢印・四角・モザイク・文字）の描画の画素と当たり判定・取り消し）
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
`capture.started` / `capture.finished` / `capture.cancelled` / `capture.{region,full,ingest}.captured` / `capture.skipped` / `capture.save_failed` /
`clipboard.copied` / `thumbnail.added` / `thumbnail.closed reason=button|dragged_out|overflow|copied|saved|ocr|pinned` / `thumbnail.saved` / `thumbnail.replaced old= new= index=` / `thumbnail.key key=esc|cmd_c|cmd_s|cmd_o|cmd_e|cmd_p` / `thumbnail.armed name= via=capture|record|restore|replace keys= editor_open= return_to= seconds=`（編集ウィンドウが開いていると keys=0） / `thumbnail.disarmed name= reason=click|app_switch|timeout|next|hover|hover_other|edit|history|record|hidden|closed ms=`（`app_switch` は `app= after_ms=` も）/ `cache.purged removed= kept=` / `history.opened kind= count= prev=` / `history.restored` / `history.closed reason=escape|toggle|restored|lost_focus|hook` / `store.failed` / `thumbnail.closed_all` / `thumbnail.drag_ended` / `thumbnail.screens_changed` / `toast.shown text= frame=` /
`ocr.done source=hotkey|thumbnail|pin|hook chars= lines= ms=` / `ocr.failed` / `pin.opened` / `pin.close_requested reason=button|menu` / `pin.closed` / `pin.opacity` /
`edit.opened px= scale= window=` / `edit.open_blocked`（描きかけがあるのに別の画像を開こうとした）/ `edit.exported name= px= annotations= kinds=` / `edit.discarded` / `edit.render_failed` / `edit.load_failed` /
`cleanshot.running`（常用版のみ）/ `launch.forward_to_running`。

## 検証フック（dev 版のみ・フォーカスを奪わない）

常駐中の dev に引数を渡す（2 個目のプロセスは引数を既存インスタンスへ転送して終了する）。
**起動ログの `launch … arm_keys=` が 0 でないインスタンスにはフックを撃たない**（`--ingest` / `--full` / `--history-restore` / `--edit-save` 等でサムネイルが出ると、5 秒間ユーザーのキーを奪う）。
撮ったものはキャッシュ（`~/Library/Caches/mycap-dev/`）に置かれ、サムネイルの「保存」で初めて保存先に書く。**保存先は `MYCAP_SAVE_DIR` で差し替えて起動し直してから撃つ**（`~/Downloads` を汚さない）。フックはクリップボードに書かない。
キャッシュの掃除（7 日）は、`touch -t $(date -v-8d +%Y%m%d%H%M)` で古くしたファイルをキャッシュに置いて起動し直すと `cache.purged removed=1` になる（`-v-2d` のものは残る）。

```bash
S=<scratchpad>; mkdir -p $S/save $S/fx
# fixture（大きさの違う画像。72dpi なのでピクセル = ポイント）
I=Sources/Assets.xcassets/AppIcon.appiconset/icon_1024.png
sips -z 540 960 $I --out $S/fx/wide.png; sips -z 900 300 $I --out $S/fx/tall.png
sips -z 20 40 $I --out $S/fx/tiny.png;  sips -z 50 3000 $I --out $S/fx/strip.png
pkill -x "mycap Dev"; while pgrep -x "mycap Dev" >/dev/null; do sleep 0.2; done
# MYCAP_ARM_KEYS=0: 撮った直後の待ち受けでキーを取らない（フックでサムネイルを出すたびにユーザーの ⌘C / Esc / ⌘S を奪わないため）。MYCAP_ARM_SECONDS で待ち受けを短く
open -g --env MYCAP_SAVE_DIR=$S/save --env MYCAP_ARM_KEYS=0 --env MYCAP_ARM_SECONDS=3 "/Applications/mycap Dev.app"
B=(open -n -g "/Applications/mycap Dev.app" --args)
"${B[@]}" --ingest $S/fx/wide.png --ingest $S/fx/tall.png --ingest $S/fx/tiny.png --ingest $S/fx/strip.png
"${B[@]}" --dump-thumbs          # hook.thumbs に最新が先頭で name / screen / frame / hovered / armed / keys
"${B[@]}" --save-newest          # 最新のサムネイルの「保存」を押す → $S/save にできる、サムネイルは閉じる（thumbnail.closed reason=saved）
"${B[@]}" --hover --snapshot $S/thumb-hover.png --unhover   # ホバー時のボタンの見た目
"${B[@]}" --full                 # 全画面（選択 UI が出ないのでフック可。許可が無ければトーストで止まる）
"${B[@]}" --remember-region 100 80 400 300   # 前回の範囲（マウスのある画面・左上原点のポイント）→ region.remembered
"${B[@]}" --last-region          # 前回と同じ範囲を撮る（許可が要る。144dpi なら 800×600 の capture.last_region.captured）
"${B[@]}" --close-all
# 撮った直後の待ち受け: 出した 1 枚が armed=true（keys=0）→ 次を出すと前が reason=next、MYCAP_ARM_SECONDS 後に reason=timeout
"${B[@]}" --ingest $S/fx/wide.png --dump-thumbs --snapshot $S/armed.png   # 枠がアクセントカラーで光る
"${B[@]}" --ingest $S/fx/tall.png --dump-thumbs; sleep 4; "${B[@]}" --dump-thumbs
"${B[@]}" --ingest $S/fx/wide.png --history-open   # reason=history（--history-restore は via=restore、--edit-save は via=replace で armed）
# クリック・アプリ切り替え・実際のキー（keys>0）は合成できないので人間が確かめる
# キャプチャ履歴（アクティブにしないで開く。動画の fixture は ffmpeg -f lavfi -i testsrc=size=640x360:rate=30 -t 3 -pix_fmt yuv420p clip.mp4）
"${B[@]}" --history-open; "${B[@]}" --history-dump   # hook.history に kind / count / focus / 各項目の 名前|相対時刻|app=|icon=|thumb=|focused
"${B[@]}" --history-focus 2 --history-kind videos --history-snapshot $S/history.png
"${B[@]}" --history-restore      # フォーカス中をサムネイルに戻す → history.restored / thumbnail.added（同じファイルが出ていたら thumbnail.closed reason=restored_again）
"${B[@]}" --history-close
# OCR（期待値は Tests/Fixtures/ocr-ja-en.txt。fixture は swift scripts/make_ocr_fixture.swift で作り直せる）
"${B[@]}" --ocr "$PWD/Tests/Fixtures/ocr-ja-en.png"      # hook.ocr text=…（改行は ⏎）
# ピン（マウスのある画面の中央に実寸。リサイズは縁と角のドラッグなので人間が確かめる）
"${B[@]}" --pin "$PWD/Tests/Fixtures/ocr-ja-en.png" --dump-pins --close-pins
# サムネイルからピン留め → サムネイルは閉じる（thumbnail.closed reason=pinned）。× はホバー中だけ出る（close_button=hidden → shown）
"${B[@]}" --ingest $S/fx/wide.png --pin-newest --dump-thumbs --dump-pins --hover-pins --dump-pins --close-pins
# Esc・ダブルクリックでは閉じない（× とメニューの「閉じる」だけ）のは、クリックが要るので人間が確かめる
# 編集（注釈は [Annotation] の JSON。座標は画像のピクセル・左上原点。end / color / text / font は省略可）
cat > $S/ann.json <<'J'
[{"kind":"rect","start":[80,60],"end":[900,260],"size":8},
 {"kind":"arrow","start":[1500,650],"end":[950,200],"size":10},
 {"kind":"mosaic","start":[100,400],"end":[700,640],"size":20},
 {"kind":"text","start":[1000,420],"size":72,"text":"ここを押す\n2行目","color":{"r":0,"g":0.478,"b":1},"font":"HiraMaruProN-W4"}]
J
"${B[@]}" --annotate "$PWD/Tests/Fixtures/ocr-ja-en.png" $S/ann.json $S/annotated.png   # 焼き込みだけ（144dpi・1800×720 のまま）
# 編集ウィンドウ → 保存でサムネイルが置き換わる（枚数は変わらず、名前が _edited に。再編集は _edited_2）
"${B[@]}" --ingest "$PWD/Tests/Fixtures/ocr-ja-en.png" --dump-thumbs
"${B[@]}" --edit-open ~/Library/Caches/mycap-dev/<撮った名前>.png --edit-load $S/ann.json --edit-select 3 --edit-dump --edit-snapshot $S/editor.png
"${B[@]}" --edit-select 0 --edit-color 3 --edit-undo --edit-dump   # 色の変更が取り消しに 1 回分積まれ、undo で戻る（undo= と color=）
"${B[@]}" --edit-save --dump-thumbs                                 # edit.exported / thumbnail.replaced（同じ frame）
```

- 位置の突き合わせは、画面の frame / visibleFrame を `swift` の小さなスクリプトで出す（`NSScreen.screens` の `NSScreenNumber` と `visibleFrame`）。最新の frame の左端 = visibleFrame.minX + 16、下端 = visibleFrame.minY + 16 になる
- 実際の画面での見た目（角丸・影・置かれた場所）は、`--ingest` で出したあとに `screencapture -x -R <x>,<y>,<w>,<h>` でその領域だけ撮って見る。`-R` は左上原点なので y = 主画面の frame の高さ − AppKit の maxY。撮影の選択 UI は出ず、許可は mycap でなく Claude Code を動かしているターミナル側のものを使う（2026-09-26 に個人 PC で撮れた）。ユーザーの画面の一部が写るので、撮る領域はサムネイルの周りに絞る
- 同じ秒に複数枚入れると `_2` `_3` が付く
- `--snapshot` はプロセス内描画なので画面収録の許可は要らない。角丸・影は写らない（レイアウトとボタンの確認用）
- `--full` を許可なしで撃つと `CGRequestScreenCaptureAccess()` が OS のダイアログを出すことがある（ユーザーの画面に出る）
- `--tcc`: 許可の状態をログに出すだけ
- キャプチャ履歴の時刻はファイル名から取る（`--ingest` のコピーは作成日時が元ファイルのものになるため）。編集の出力（`_edited`）だけ作成日時。`--history-snapshot` はプロセス内描画なので、すりガラスの背景は灰色に写る
- キャプチャ履歴のキー操作（←→ / Enter / Esc / Tab）・ホバー・ダブルクリック・外クリックで閉じる・閉じたあと元のアプリに戻るは、パネルを key にする必要がありフォーカスを奪うので、人間が ⌃⌥⌘3 で確かめる
- 前回の範囲は `defaults read io.github.nyshk97.mycap.dev lastRegion` にある。確認後は `defaults delete` で消す（メニューの「前回と同じ範囲を撮る」が有効のまま残る）。⌘⇧4 のドラッグで覚える経路は `screencapture -i` が要るので人間が確かめる（ログの `region.remembered` / `region.remember_skipped reason=…`）
- `--edit-snapshot` はキャンバス（画像・注釈・選択枠）と色の丸は写るが、ツールバーのスライダー・ボタンの文字はプロセス内描画に出ない。ツールバーの見た目・マウスで描く・文字の入力（日本語の変換）・⌘Z / ⌘S / Esc は、ウィンドウを key にする必要があるので人間が確かめる
- **ユーザーが dev 版を触っている間は編集のフックを撃たない**。`--edit-close` は確認なしで破棄し、`--close-all` はサムネイルを全部閉じる（2026-09-26 に、ユーザーが ⌘E で描いていたモザイクを消した実例）。撃つ前に `tail ~/Library/Logs/mycap/mycap-dev.log` で `thumbnail.key` / `edit.opened` が自分のフック以外から出ていないか見る。`--edit-open` は描きかけがあると `edit.open_blocked` で開かない
- フックを渡すだけの 2 個目のプロセスは `launch.forward_to_running` の 1 行だけを出して終わる（`thumbnail.*` 等が出たら、単一インスタンスの判定より前に何かを作っている）

## 画面収録の許可（TCC）

- 許可の状態は `tcc.preflight` の行で見る。起動時・撮影の前後に必ず出る
- **Claude Code のセッションからのビルドは常に ad-hoc**（`CLAUDECODE` を見て `CODE_SIGN_IDENTITY=-` を渡す）で、リビルドごとに許可が外れる。許可が続くかを見るのは、ユーザーが自分の Terminal で `mise run signing` → `mise run run` したビルドで
- 許可が署名で安定しているかは、2 回のビルドで designated requirement が一致するかで見る:
  `codesign -dr - "/Applications/mycap Dev.app"`（ハッシュ直指定でなく、証明書の identifier と Team で書かれていれば安定）
- 許可を付け直すときは `tccutil reset ScreenCapture io.github.nyshk97.mycap.dev`
- 撮影（`screencapture -i`）は OS の範囲選択 UI がユーザーの画面に出るため、AI からは撃たない。人間が ⌃⌥⌘4 を押し、AI はログの `capture.*` と `tcc.preflight` で確かめる

## メニューバーのアイコン

`StatusIcon.swift` をそのまま `swiftc` で小さな描画プログラムと一緒にコンパイルし、PNG に書き出して見る（アプリを起動せずに確認できる）。
