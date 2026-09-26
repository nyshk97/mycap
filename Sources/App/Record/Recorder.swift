import AppKit
import AVFoundation
import ScreenCaptureKit

/// 動画録画。オールインワン（⌘⇧5）で選んだ範囲を、3 秒のカウントダウンのあと
/// SCRecordingOutput で mp4（1x・H.264・30fps・カーソルあり）に書く。
/// 録画中は範囲の外側に枠と停止バーを出す（mycap のウィンドウはフィルタで外すうえ、枠は範囲の外なので写らない）
final class Recorder: NSObject, SCStreamDelegate, SCRecordingOutputDelegate {
    enum State: String { case idle, countdown, recording, stopping }

    private(set) var state: State = .idle { didSet { onStateChange?() } }
    private(set) var startedAt: Date?
    /// 状態が変わったとき（メニューバーの表示を切り替える）
    var onStateChange: (() -> Void)?
    /// 録れた mp4（キャッシュに置いたもの）を受け取る（サムネイルを出す）
    var onSaved: ((URL, NSScreen) -> Void)?

    private let countdown = Countdown(logPrefix: "record")
    private let frame = RecordingFrame()
    private let bar = RecordingBar()
    private var stream: SCStream?
    private var output: SCRecordingOutput?
    private var tmpURL: URL?
    private var targetScreen: NSScreen = .underMouse
    private var stopReason = "user"
    /// 履歴のアイコン用。オールインワンを開いたときの前面アプリ
    private var sourceApp: String?

    /// ⌘⇧5 の振り分け（`AIOController`）から: カウントダウン中ならキャンセル、録画中なら停止
    func toggle() {
        switch state {
        case .idle: Log.write("record.toggle_ignored state=idle")
        case .countdown: countdown.cancel()
        case .recording: stop(reason: "user")
        case .stopping: break
        }
    }

    /// 範囲（ディスプレイ内の左上原点のポイント）を、カウントダウンのあと録る
    func start(screen: NSScreen, rect: CGRect, app: String?) {
        guard state == .idle else {
            Log.write("record.start_ignored state=\(state.rawValue)")
            return
        }
        sourceApp = app
        targetScreen = screen
        state = .countdown
        Log.write("record.region screen=\(screen.displayID) rect=\(NSStringFromRect(rect))")
        countdown.start(seconds: 3, on: screen, finish: { [weak self] in
            self?.begin(screen: screen, rect: rect)
        }, cancel: { [weak self] in
            self?.state = .idle
        })
    }

    /// 検証フック `--record-display <秒>` / `--aio-record x y w h <秒>`: カウントダウンを飛ばして、マウスのある画面（か、その範囲）を録る
    func startForTest(seconds: Double, rect: CGRect? = nil) {
        guard state == .idle else { return }
        targetScreen = .underMouse
        sourceApp = CaptureStore.frontmostAppID()
        state = .countdown
        begin(screen: targetScreen, rect: rect)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in self?.stop(reason: "test") }
    }

    // MARK: - 録画

    /// 自分のウィンドウ（サムネイル・ピン・枠等）を外したディスプレイのフィルタで録る。`rect` があればその範囲だけ
    private func begin(screen: NSScreen, rect: CGRect?) {
        let displayID = screen.displayID
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
            DispatchQueue.main.async {
                guard let content, let display = content.displays.first(where: { $0.displayID == displayID }) else {
                    Log.write("record.no_display id=\(displayID) error=\(String(describing: error))")
                    self.state = .idle
                    Toast.shared.show("録画を始められませんでした")
                    return
                }
                let mine = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
                self.start(with: SCContentFilter(display: display, excludingApplications: mine, exceptingWindows: []), rect: rect)
            }
        }
    }

    private func start(with filter: SCContentFilter, rect: CGRect?) {
        let size = RecordingFormat.outputSize(points: rect?.size ?? filter.contentRect.size)
        let config = SCStreamConfiguration()
        if let rect {
            // 縮めないときは、範囲も出力（偶数）と同じ大きさに削る（右・下を 1pt）。1pt 未満の縮小で全体がぼやけないように
            let exact = CGFloat(size.width) <= rect.width && CGFloat(size.height) <= rect.height
                && max(rect.width, rect.height) <= RecordingFormat.maxDimension
            config.sourceRect = exact ? CGRect(x: rect.minX, y: rect.minY, width: CGFloat(size.width), height: CGFloat(size.height)) : rect
        }
        config.width = size.width
        config.height = size.height
        config.minimumFrameInterval = CMTime(value: 1, timescale: RecordingFormat.fps)
        config.showsCursor = true
        config.capturesAudio = false

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mycap-\(UUID().uuidString).mp4")
        let rc = SCRecordingOutputConfiguration()
        rc.outputURL = tmp
        rc.outputFileType = .mp4
        rc.videoCodecType = .h264
        let output = SCRecordingOutput(configuration: rc, delegate: self)
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        do {
            try stream.addRecordingOutput(output)
        } catch {
            Log.write("record.add_output_failed error=\(error)")
            state = .idle
            Toast.shared.show("録画を始められませんでした")
            return
        }
        self.stream = stream
        self.output = output
        tmpURL = tmp
        stopReason = "user"
        let screen = targetScreen
        stream.startCapture { error in
            DispatchQueue.main.async {
                if let error {
                    Log.write("record.start_failed error=\(error)")
                    self.cleanup()
                    self.state = .idle
                    Toast.shared.show("録画を始められませんでした")
                    return
                }
                self.startedAt = Date()
                self.state = .recording
                if let rect {
                    let global = AIOLayout.global(rect, screenFrame: screen.frame)
                    self.frame.show(around: global)
                    self.bar.show(around: global, on: screen, startedAt: self.startedAt ?? Date()) { [weak self] in
                        self?.stop(reason: "bar")
                    }
                }
                Log.write("record.started size=\(size.width)x\(size.height) fps=\(RecordingFormat.fps) rect=\(rect.map { NSStringFromRect($0) } ?? "display")")
            }
        }
    }

    func stop(reason: String) {
        guard state == .recording, let stream else { return }
        stopReason = reason
        state = .stopping
        frame.hide()
        bar.hide()
        stream.stopCapture { error in
            if let error { Log.write("record.stop_error error=\(error)") }
            // ファイルの確定は recordingOutputDidFinishRecording で受ける。来なければ 3 秒後にここで確定させる
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                if self.state == .stopping {
                    Log.write("record.finish_timeout")
                    self.finishRecording()
                }
            }
        }
    }

    // SCStreamDelegate: 対象のウィンドウが閉じられた等で SCK 側から止まったとき。そこまでを保存する
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async {
            Log.write("record.stream_stopped error=\(error)")
            if self.state == .recording {
                self.stopReason = "stream_stopped"
                self.state = .stopping
            }
            // didFinishRecording が来ないことがあるので、少し待っても来なければここで確定させる
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                if self.state == .stopping { self.finishRecording() }
            }
        }
    }

    func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        Log.write("record.output_started")
    }

    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        DispatchQueue.main.async {
            Log.write("record.output_failed error=\(error)")
            self.finishRecording()
        }
    }

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        DispatchQueue.main.async { self.finishRecording() }
    }

    private func finishRecording() {
        guard state == .stopping || state == .recording, let tmp = tmpURL else { return }
        let duration = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        let reason = stopReason
        let screen = targetScreen
        cleanup()
        state = .idle
        guard FileManager.default.fileExists(atPath: tmp.path) else {
            Log.write("record.no_file reason=\(reason)")
            Toast.shared.show("録画を保存できませんでした")
            return
        }
        guard let saved = CaptureStore.keep(tmp, app: sourceApp) else {
            Toast.shared.show("録画を置けませんでした: \(Env.cacheDir.path)")
            return
        }
        Log.write("record.captured path=\(saved.path) seconds=\(String(format: "%.1f", duration)) reason=\(reason)")
        if reason == "stream_stopped" { Toast.shared.show("録画が途中で止まりました。そこまでを保存しました") }
        onSaved?(saved, screen)
    }

    private func cleanup() {
        frame.hide()
        bar.hide()
        stream = nil
        output = nil
        tmpURL = nil
        startedAt = nil
    }
}
