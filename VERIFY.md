# 動作確認手順

## ビルドとテスト

```bash
mise run build          # Debug（mycap Dev）。署名 xcconfig が無ければ ad-hoc で通る
mise run build-release  # Release（mycap）
mise run test           # Sources/Core の純粋関数（ファイル名の規則 等）
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
`capture.started` / `capture.finished` / `capture.cancelled` / `capture.region.captured` / `capture.skipped` /
`cleanshot.running`（常用版のみ）/ `launch.forward_to_running`。

## 検証フック（dev 版のみ・画面にもフォーカスにも触らない）

常駐中の dev に引数を渡す（2 個目のプロセスは引数を既存インスタンスへ転送して終了する）。

```bash
open -n -g "/Applications/mycap Dev.app" --args --tcc
tail -3 ~/Library/Logs/mycap/mycap-dev.log   # launch.forward_to_running と tcc.preflight granted=… when=hook
```

## 画面収録の許可（TCC）

- 許可の状態は `tcc.preflight` の行で見る。起動時・撮影の前後に必ず出る
- **Claude Code のセッションからのビルドは常に ad-hoc**（`CLAUDECODE` を見て `CODE_SIGN_IDENTITY=-` を渡す）で、リビルドごとに許可が外れる。許可が続くかを見るのは、ユーザーが自分の Terminal で `mise run signing` → `mise run run` したビルドで
- 許可が署名で安定しているかは、2 回のビルドで designated requirement が一致するかで見る:
  `codesign -dr - "/Applications/mycap Dev.app"`（ハッシュ直指定でなく、証明書の identifier と Team で書かれていれば安定）
- 許可を付け直すときは `tccutil reset ScreenCapture io.github.nyshk97.mycap.dev`
- 撮影（`screencapture -i`）は OS の範囲選択 UI がユーザーの画面に出るため、AI からは撃たない。人間が ⌃⌥⌘4 を押し、AI はログの `capture.*` と `tcc.preflight` で確かめる

## メニューバーのアイコン

`StatusIcon.swift` をそのまま `swiftc` で小さな描画プログラムと一緒にコンパイルし、PNG に書き出して見る（アプリを起動せずに確認できる）。
