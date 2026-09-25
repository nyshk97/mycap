# mycap

CleanShot X のうち使っている機能（範囲・ウィンドウ・全画面のキャプチャ、OCR、ピン留め、撮影後のサムネイル、動画録画、デスクトップアイコン隠し、背景と余白の整形）だけを持つ自分用のスクリーンショットアプリ。
兄弟アプリ `~/mycast`（Raycast 代替）と同じ型で作っている。Swift + AppKit（パネルの中身は SwiftUI）+ XcodeGen。`project.yml` が真実の源で `.xcodeproj` は生成物。
計画と決定の経緯は `docs/plans/`、動作確認は `VERIFY.md`。

## 固定の挙動（設定画面は作らない）

挙動は固定値としてコードに焼き込む。変えたくなったらコードを直してリリースする。

- ホットキー（`Sources/App/HotKeys.swift`。Carbon の `RegisterEventHotKey` なのでアクセシビリティ許可は要らない）: 常用 ⌘⇧2 OCR / ⌘⇧3 全画面 / ⌘⇧4 範囲・ウィンドウ / ⌘⇧5 録画。dev は ⌃⌥⌘ ＋ 同じ数字
- OS 標準のスクショショートカットはシステム設定でオフにしてある前提（2026-09-25 に確認）。常用版は CleanShot X と同じキーを取り合うので、CleanShot X が動いていたらメニューバーで警告する
- 保存先は `~/Downloads`、ファイル名は `YYYY-MM-DD_HH-mm-ss.png` / `.mp4`（同じ秒なら `_2`…）→ `Sources/Core/FileNaming.swift`

## コマンド

`.mise.toml` の tasks を見る。主なもの: `mise run build` / `test` / `run`（dev を /Applications に置いて起動）/ `log` / `release`。

## 会社貸与 PC での制約

会社貸与 PC（判定はグローバルの CLAUDE.md）では Claude Code のセッションから keychain に触らない。
`mise run signing`（証明書の解決）・`mise run release`・`generate_keys` / `sign_update` はユーザーが自分の Terminal で叩く。
セッションのビルドは署名 xcconfig が無ければ ad-hoc になる（`scripts/ensure-signing-xcconfig.sh`）。ad-hoc はリビルドごとに画面収録の許可が外れる。

## 構成

- `Sources/Core/` — 純粋関数（テスト対象。テストはアプリをホストにせずこのディレクトリだけをコンパイルする）
- `Sources/App/` — 起動・単一インスタンス・ホットキー・メニューバー・`screencapture` の呼び出し

## 罠

- 画面収録の許可（TCC）は `screencapture` を呼んだこのアプリが持ち主になる。許可の状態は撮るたびに `tcc.preflight` としてログに残している（Tahoe の定期的な再確認の頻度をあとで数えるため。消さない）
- 検証で `NSPasteboard` に書かない（ユーザーのクリップボードを上書きする）
- `screencapture -i` は OS の範囲選択 UI をユーザーの画面に出すので、AI から撃たない
