# mycap

CleanShot X のうち使っている機能（範囲・ウィンドウ・全画面のキャプチャ、OCR、ピン留め、撮影後のサムネイル、キャプチャ履歴、動画録画、撮った画像への注釈（矢印・四角・モザイク・文字））だけを持つ自分用のスクリーンショットアプリ。
兄弟アプリ `~/mycast`（Raycast 代替）と同じ型で作っている。Swift + AppKit（パネルの中身は SwiftUI）+ XcodeGen。`project.yml` が真実の源で `.xcodeproj` は生成物。
計画と決定の経緯は `docs/plans/`、動作確認は `VERIFY.md`。

## 固定の挙動（設定画面は作らない）

挙動は固定値としてコードに焼き込む。変えたくなったらコードを直してリリースする。

- ホットキー（`Sources/App/HotKeys.swift`。Carbon の `RegisterEventHotKey` なのでアクセシビリティ許可は要らない）: 常用 ⌘⇧3 キャプチャ履歴 / ⌘⇧4 範囲・ウィンドウ / ⌘⇧5 オールインワン / ⌘⇧6 前回と同じ範囲。dev は ⌃⌥⌘ ＋ 同じ数字。OCR・全画面はメニューからだけ
- オールインワン（⌘⇧5、`Sources/App/AIO/`）は自前の暗幕で範囲を選び、Capture / Scrolling / Recording をその範囲に行う。録画はこの範囲の録画だけ（ウィンドウ単位の録画は無い）。録画中・カウントダウン中の ⌘⇧5 は停止／キャンセル。録画中は範囲の右下の外に経過時間と ■ 停止のバーを出す（メニューバーの ● のクリックでも止まる）。暗幕は `.nonactivatingPanel` で mycap を前面にしない（前面にすると元のアプリが非アクティブの見た目で写る）
- スクロールキャプチャ（オールインワンの Scrolling、`Sources/App/Scroll/`）はユーザーが手でスクロールする（自動スクロールはアクセシビリティ許可が要るので作らない）。SCStream で 15fps のコマを受け、`ScrollStitcher`（`Sources/Core`）が「最後につないだコマ」との行シグネチャの照合で dy を出して、新しく見えた行だけを足す。固定ヘッダ・フッタは最初に dy が決まった組で決め、1 回ずつだけ入れる。上へのスクロール・一致の弱いコマ・あいまいなコマ（周期的・無地）は捨てる。範囲はスクロールする部分だけを選ぶ前提（動かないサイドバーが入ると一致しない）。終わりはバーの Done・⌘⇧5・メニューバーの ●（Cancel はバーだけ）。高さの上限は 30000px。撮影中はほかの撮影のホットキーを受けない
- OS 標準のスクショショートカットはシステム設定でオフにしてある前提（2026-09-25 に確認）。常用版は CleanShot X と同じキーを取り合うので、CleanShot X が動いていたらメニューバーで警告する
- 撮ったもの（静止画・録画・編集の出力）はキャッシュ（`~/Library/Caches/mycap/`、dev は `mycap-dev/`）に置くだけ。`~/Downloads` への保存とコピーは、サムネイルのボタンを押したときだけ。自動でクリップボードに入れるのは OCR の文字だけ。キャッシュは 7 日で、起動時と 1 日 1 回掃除する。キャプチャ履歴（⌘⇧3）はこのキャッシュの一覧で、Restore で撮影直後のサムネイルに戻す。撮ったときの前面アプリの bundle id は拡張属性 `io.github.nyshk97.mycap.source-app` に持つ
- サムネイルのキー（Esc / ⌘C / ⌘S / ⌘O / ⌘E / ⌘P。録画は Esc / ⌘C / ⌘S / ⌘E と、ホバー中だけ Space）はホバー中と、出した直後の「待ち受け」中だけ効く。待ち受けは枠が光り、クリック・前面アプリの切り替え（撮影・Restore・編集の直後に元のアプリへ戻る分は除く）・5 秒・編集／履歴／オールインワンを開く・マウスを乗せる、で解ける。マウスの移動では解けない。キーを持つサムネイルは常に 1 枚
- 録画のサムネイル（CleanShot X 風。アップロードは無し）: 普段は左下に長さ・大きさ（音声があれば 🔊）。ホバー中はサムネイルの中で無音ループ再生し、左上 閉じる / 右上 プレビュー（Space）/ 左下 トリム（⌘E・ダブルクリック）/ 右下 コピー（⌘C。ファイルそのもの）/ 中央 Save。トリムは AVPlayerView 標準のトリム UI で、`<元>_edited.mp4` をキャッシュに書いて元のサムネイルを置き換える（`Sources/App/Video/`）
- 編集（サムネイルの左下のボタン / ⌘E）は注釈をデータで持ち、⌘S で `<元>_edited.png` をキャッシュに書いて元のサムネイルを置き換える。スクショの周りの背景・余白・角丸・影（以前の整形）は付けない
- 保存先は `~/Downloads`、ファイル名は `YYYY-MM-DD_HH-mm-ss.png` / `.mp4`（同じ秒なら `_2`…）→ `Sources/Core/FileNaming.swift`

## コマンド

`.mise.toml` の tasks を見る。主なもの: `mise run build` / `test` / `run`（dev を /Applications に置いて起動）/ `log` / `release`。

## 会社貸与 PC での制約

会社貸与 PC（判定はグローバルの CLAUDE.md）では Claude Code のセッションから keychain に触らない。
`mise run signing`（証明書の解決）・`mise run release`・`generate_keys` / `sign_update` はユーザーが自分の Terminal で叩く。
セッション（環境変数 `CLAUDECODE` が立っている）からの `mise run build` / `build-release` / `test` は、署名 xcconfig があっても xcodebuild に `CODE_SIGN_IDENTITY=-` を渡して ad-hoc にする（`.mise.toml`）。
ad-hoc はリビルドごとに画面収録の許可が外れるので、許可が要る確認（実際に撮る）はユーザーが自分の Terminal で `mise run run` して行う。セッションの検証は検証フックとログで済ませる。
個人 PC のセッションから dev 版を入れるときは `env -u CLAUDECODE mise run run` にする。Claude Code は子プロセスに環境変数 `CLAUDECODE=1` を渡し、`.mise.toml` はそれを見て ad-hoc 署名にする（会社貸与 PC で keychain に触らないため）。ad-hoc だとリビルドのたびに画面収録の許可が外れる。

## 構成

- `Sources/Core/` — 純粋関数（テスト対象。テストはアプリをホストにせずこのディレクトリだけをコンパイルする）
- `Sources/App/` — 起動・単一インスタンス・ホットキー・メニューバー・`screencapture` の呼び出し

## 罠

- 画面収録の許可（TCC）は `screencapture` を呼んだこのアプリが持ち主になる。許可の状態は撮るたびに `tcc.preflight` としてログに残している（Tahoe の定期的な再確認の頻度をあとで数えるため。消さない）
- 検証で `NSPasteboard` に書かない（ユーザーのクリップボードを上書きする）
- `screencapture -i` は OS の範囲選択 UI をユーザーの画面に出すので、AI から撃たない
