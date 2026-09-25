import AppKit

/// 静止画の撮影から撮影後の処理（保存 → コピー → サムネイル）までの流れ
final class CaptureService {
    let thumbnails = ThumbnailController()
    private let capturer = ScreenCapturer()
    private var fullScreenRunning = false

    /// 範囲／ウィンドウ（Space で切り替え）
    func captureRegion() {
        guard ensurePermission() else { return }
        thumbnails.setHidden(true)
        capturer.capture(.interactive) { [weak self] tmp in
            guard let self else { return }
            thumbnails.setHidden(false)
            guard let tmp else {
                Log.write("capture.cancelled mode=region")
                return
            }
            finish(tmp: tmp, kind: "region", screen: .underMouse, copy: true)
        }
    }

    /// マウスのあるディスプレイ全体。`copy: false` は検証フック `--full` 用（クリップボードを上書きしない）
    func captureFullScreen(copy: Bool = true) {
        guard ensurePermission(), !fullScreenRunning else { return }
        fullScreenRunning = true
        let screen = NSScreen.underMouse
        Log.write("capture.started mode=full screen=\(screen.displayID)")
        FullScreenCapturer.capture(screen: screen) { [weak self] tmp in
            guard let self else { return }
            fullScreenRunning = false
            ScreenCapturer.logPermission(when: "after_capture")
            guard let tmp else {
                Toast.shared.show("全画面を撮れませんでした")
                return
            }
            finish(tmp: tmp, kind: "full", screen: screen, copy: copy)
        }
    }

    /// 検証フック `--ingest`: 既存の画像を撮影結果として同じ経路に流す。クリップボードには書かない
    func ingest(path: String) {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mycap-\(UUID().uuidString).png")
        do {
            try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: tmp)
        } catch {
            Log.write("hook.ingest_failed path=\(path) error=\(error)")
            return
        }
        finish(tmp: tmp, kind: "ingest", screen: .underMouse, copy: false)
    }

    private func finish(tmp: URL, kind: String, screen: NSScreen, copy: Bool) {
        guard let saved = save(tmp) else {
            Toast.shared.show("保存できませんでした: \(Env.saveDir.path)")
            return
        }
        if copy { ImageClipboard.copy(saved) }
        let px = NSImage(contentsOf: saved)?.representations.first.map { "\($0.pixelsWide)x\($0.pixelsHigh)" } ?? "?"
        Log.write("capture.\(kind).saved path=\(saved.path) px=\(px) copied=\(copy)")
        thumbnails.add(url: saved, screen: screen)
    }

    private func save(_ tmp: URL) -> URL? {
        let fm = FileManager.default
        let dir = Env.saveDir
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let name = FileNaming.uniqueName(stem: FileNaming.stem(for: Date()), ext: "png") {
                fm.fileExists(atPath: dir.appendingPathComponent($0).path)
            }
            let dest = dir.appendingPathComponent(name)
            try fm.moveItem(at: tmp, to: dest)
            return dest
        } catch {
            Log.write("capture.save_failed error=\(error)")
            return nil
        }
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
