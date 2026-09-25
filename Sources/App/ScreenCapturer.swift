import AppKit
import CoreGraphics

/// `screencapture` を呼んで静止画を一時ファイルに撮る。範囲選択 UI は OS 標準のものを使う。
/// TCC は呼び出し元（このアプリ）を画面収録の許可の持ち主として見るので、撮るたびに許可の状態をログに残す
/// （Tahoe の定期的な再確認がどのくらいの頻度で出るかを、あとからログで数えるため）
final class ScreenCapturer {
    enum Mode: String {
        /// 範囲／ウィンドウ（Space で切り替え）
        case interactive
    }

    private var running: Process?

    var isRunning: Bool { running != nil }

    /// 撮れたら一時ファイルの URL、キャンセル（Esc）や失敗なら nil を main で返す
    func capture(_ mode: Mode, completion: @escaping (URL?) -> Void) {
        guard running == nil else {
            Log.write("capture.skipped reason=already_running")
            return
        }
        Self.logPermission(when: "before_capture")
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mycap-\(UUID().uuidString).png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        switch mode {
        case .interactive:
            process.arguments = ["-i", "-x", tmp.path]
        }
        process.terminationHandler = { [weak self] p in
            DispatchQueue.main.async {
                self?.running = nil
                let exists = FileManager.default.fileExists(atPath: tmp.path)
                Log.write("capture.finished mode=\(mode.rawValue) status=\(p.terminationStatus) file=\(exists)")
                Self.logPermission(when: "after_capture")
                completion(exists ? tmp : nil)
            }
        }
        do {
            try process.run()
            running = process
            Log.write("capture.started mode=\(mode.rawValue) pid=\(process.processIdentifier)")
        } catch {
            Log.write("capture.launch_failed \(error)")
            completion(nil)
        }
    }

    static func logPermission(when: String) {
        Log.write("tcc.preflight granted=\(CGPreflightScreenCaptureAccess()) when=\(when)")
    }
}
