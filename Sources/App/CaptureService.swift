import AppKit

/// 静止画の撮影から撮影後の処理（キャッシュに置く → サムネイル）までの流れ
final class CaptureService {
    let thumbnails = ThumbnailController()
    let pins = PinController()
    let editor = EditorController()
    let recorder = Recorder()
    let history = HistoryController()

    init() {
        thumbnails.onPin = { [weak self] url in self?.pins.pin(url: url) }
        thumbnails.onEdit = { [weak self] url in self?.editor.open(url) }
        editor.onSaved = { [weak self] source, out in self?.thumbnails.replace(source, with: out) }
        recorder.onSaved = { [weak self] url, screen in self?.thumbnails.add(url: url, screen: screen) }
        history.onRestore = { [weak self] url, screen in self?.thumbnails.restore(url: url, screen: screen) }
    }
    private let capturer = ScreenCapturer()
    private let drag = DragTracker()
    private var fullScreenRunning = false

    /// 範囲／ウィンドウ（Space で切り替え）
    func captureRegion() {
        guard ensurePermission() else { return }
        let app = CaptureStore.frontmostAppID()
        thumbnails.setHidden(true)
        drag.start()
        capturer.capture(.interactive) { [weak self] tmp in
            guard let self else { return }
            drag.stop()
            thumbnails.setHidden(false)
            guard let tmp else {
                Log.write("capture.cancelled mode=region")
                return
            }
            rememberRegion(image: tmp)
            finish(tmp: tmp, kind: "region", screen: .underMouse, app: app)
        }
    }

    /// ドラッグで範囲を選んだときだけ「前回の範囲」を更新する（ウィンドウを撮ったときは前の範囲のまま）
    private func rememberRegion(image: URL) {
        guard let down = drag.down, let up = drag.up else {
            Log.write("region.remember_skipped reason=no_drag")
            return
        }
        let mid = CGPoint(x: (down.x + up.x) / 2, y: (down.y + up.y) / 2)
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mid, $0.frame, false) }),
              let rep = NSImage(contentsOf: image)?.representations.first else {
            Log.write("region.remember_skipped reason=no_screen")
            return
        }
        let px = CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        guard let rect = RegionMemory.rect(from: down, to: up, imagePixels: px, scale: screen.backingScaleFactor),
              let local = RegionMemory.local(rect, in: screen.frame) else {
            Log.write("region.remember_skipped reason=size_mismatch down=\(down) up=\(up) px=\(px)")
            return
        }
        LastRegion.save(LastRegion(displayID: screen.displayID, rect: local))
    }

    /// 前回ドラッグで選んだ範囲を、選択 UI を出さずに撮る
    func captureLastRegion() {
        guard let region = LastRegion.load() else {
            Toast.shared.show("前回の範囲がありません。先に \(HotKeyBindings.region.label) で範囲をドラッグして撮ってください")
            return
        }
        guard let screen = NSScreen.withID(region.displayID) else {
            Toast.shared.show("前回の範囲のディスプレイが見つかりません")
            Log.write("capture.last_region.no_display id=\(region.displayID)")
            return
        }
        guard ensurePermission(), !fullScreenRunning else { return }
        fullScreenRunning = true
        let app = CaptureStore.frontmostAppID()
        Log.write("capture.started mode=last_region screen=\(screen.displayID) rect=\(NSStringFromRect(region.rect))")
        FullScreenCapturer.capture(screen: screen, rect: region.rect) { [weak self] tmp in
            guard let self else { return }
            fullScreenRunning = false
            ScreenCapturer.logPermission(when: "after_capture")
            guard let tmp else {
                Toast.shared.show("前回の範囲を撮れませんでした")
                return
            }
            finish(tmp: tmp, kind: "last_region", screen: screen, app: app)
        }
    }

    /// 録画の開始（対象を選ぶ）／カウントダウンのキャンセル／停止
    func toggleRecording() {
        if recorder.state == .idle, !ensurePermission() { return }
        recorder.toggle()
    }

    /// 範囲を選んで文字を読む。画像は保存せず、サムネイルも出さない
    func captureOCR() {
        guard ensurePermission() else { return }
        thumbnails.setHidden(true)
        capturer.capture(.interactive) { [weak self] tmp in
            self?.thumbnails.setHidden(false)
            guard let tmp else {
                Log.write("capture.cancelled mode=ocr")
                return
            }
            OCR.recognizeAndCopy(url: tmp, source: "hotkey") { _ in
                try? FileManager.default.removeItem(at: tmp)
            }
        }
    }

    /// マウスのあるディスプレイ全体
    func captureFullScreen() {
        guard ensurePermission(), !fullScreenRunning else { return }
        fullScreenRunning = true
        let screen = NSScreen.underMouse
        let app = CaptureStore.frontmostAppID()
        Log.write("capture.started mode=full screen=\(screen.displayID)")
        FullScreenCapturer.capture(screen: screen) { [weak self] tmp in
            guard let self else { return }
            fullScreenRunning = false
            ScreenCapturer.logPermission(when: "after_capture")
            guard let tmp else {
                Toast.shared.show("全画面を撮れませんでした")
                return
            }
            finish(tmp: tmp, kind: "full", screen: screen, app: app)
        }
    }

    /// 検証フック `--ingest`: 既存の画像（または mp4）を撮影結果として同じ経路に流す
    func ingest(path: String) {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased() == "mp4" ? "mp4" : "png"
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mycap-\(UUID().uuidString).\(ext)")
        do {
            try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: tmp)
        } catch {
            Log.write("hook.ingest_failed path=\(path) error=\(error)")
            return
        }
        finish(tmp: tmp, kind: "ingest", screen: .underMouse, app: CaptureStore.frontmostAppID())
    }

    /// キャッシュに置いてサムネイルを出す。保存・コピーはサムネイルのボタンを押したときだけ（ユーザー判断）
    private func finish(tmp: URL, kind: String, screen: NSScreen, app: String?) {
        guard let kept = CaptureStore.keep(tmp, app: app) else {
            Toast.shared.show("撮った画像を置けませんでした: \(Env.cacheDir.path)")
            return
        }
        let px = NSImage(contentsOf: kept)?.representations.first.map { "\($0.pixelsWide)x\($0.pixelsHigh)" } ?? "?"
        Log.write("capture.\(kind).captured path=\(kept.path) px=\(px) app=\(app ?? "-")")
        thumbnails.add(url: kept, screen: screen)
    }

    /// 許可が無いときの `screencapture -i` は Esc と区別の付かない終わり方をするので、撮る前に止めて知らせる
    private func ensurePermission() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        ScreenCapturer.logPermission(when: "denied")
        CGRequestScreenCaptureAccess()
        Toast.shared.show("画面収録の許可がありません。クリックでシステム設定を開きます", action: {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        })
        return false
    }
}
