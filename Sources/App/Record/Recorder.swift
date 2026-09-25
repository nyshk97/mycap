import AppKit
import AVFoundation
import ScreenCaptureKit

/// 動画録画。OS 標準の SCContentSharingPicker でディスプレイかウィンドウを選び、3 秒のカウントダウンのあと
/// SCRecordingOutput で mp4（1x・H.264・30fps・カーソルあり）に書く。
/// 同じホットキーで 選ぶ → （カウントダウン中ならキャンセル）→ 録画中なら停止 と進む
final class Recorder: NSObject, SCContentSharingPickerObserver, SCStreamDelegate, SCRecordingOutputDelegate {
    enum State: String { case idle, picking, countdown, recording, stopping }

    private(set) var state: State = .idle { didSet { onStateChange?() } }
    private(set) var startedAt: Date?
    /// 状態が変わったとき（メニューバーの表示を切り替える）
    var onStateChange: (() -> Void)?
    /// 保存できた mp4 を受け取る（サムネイルを出す）
    var onSaved: ((URL, NSScreen) -> Void)?

    private let countdown = Countdown()
    private var stream: SCStream?
    private var output: SCRecordingOutput?
    private var tmpURL: URL?
    private var targetScreen: NSScreen = .underMouse
    private var stopReason = "user"

    /// ホットキー・メニューから
    func toggle() {
        switch state {
        case .idle: pick()
        case .picking: Log.write("record.toggle_ignored state=picking")
        case .countdown: countdown.cancel()
        case .recording: stop(reason: "user")
        case .stopping: break
        }
    }

    // MARK: - 対象を選ぶ

    private func pick() {
        let picker = SCContentSharingPicker.shared
        var config = SCContentSharingPickerConfiguration()
        config.allowedPickerModes = [.singleWindow, .singleDisplay]
        if let id = Bundle.main.bundleIdentifier { config.excludedBundleIDs = [id] }
        picker.defaultConfiguration = config
        picker.add(self)
        picker.isActive = true
        state = .picking
        picker.present()
        Log.write("record.picker_presented")
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        DispatchQueue.main.async { self.picked(filter) }
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        DispatchQueue.main.async {
            Log.write("record.picker_cancelled")
            self.finishPicker()
            self.state = .idle
        }
    }

    func contentSharingPickerStartDidFailWithError(_ error: Error) {
        DispatchQueue.main.async {
            Log.write("record.picker_failed error=\(error)")
            self.finishPicker()
            self.state = .idle
            Toast.shared.show("録画の対象を選べませんでした")
        }
    }

    private func finishPicker() {
        SCContentSharingPicker.shared.remove(self)
        SCContentSharingPicker.shared.isActive = false
    }

    /// picker で選んだフィルタは picker が与えたアクセス権にぶら下がるので、picker は録画が終わるまでアクティブのままにする
    /// （選んだ直後に isActive = false にすると、ウィンドウの録画が「The stream is nil」で始まらなかった）
    private func picked(_ pickerFilter: SCContentFilter) {
        guard state == .picking else { return }
        let isDisplay = pickerFilter.style == .display
        let displayID = pickerFilter.includedDisplays.first?.displayID
        targetScreen = displayID.flatMap(NSScreen.withID) ?? .underMouse
        Log.write("record.picked style=\(isDisplay ? "display" : "window") raw_style=\(pickerFilter.style.rawValue) displays=\(pickerFilter.includedDisplays.count) windows=\(pickerFilter.includedWindows.count) rect=\(NSStringFromRect(pickerFilter.contentRect))")
        state = .countdown
        countdown.start(seconds: 3, on: targetScreen, finish: { [weak self] in
            self?.begin(pickerFilter, isDisplay: isDisplay, displayID: displayID)
        }, cancel: { [weak self] in
            self?.finishPicker()
            self?.state = .idle
        })
    }

    // MARK: - 録画

    /// ディスプレイのときは、自分のウィンドウ（サムネイル・ピン等）を外したフィルタに作り直す。
    /// ウィンドウのときは、そのウィンドウだけが写るので picker のフィルタをそのまま使う
    private func begin(_ pickerFilter: SCContentFilter, isDisplay: Bool, displayID: CGDirectDisplayID?) {
        guard isDisplay, let displayID else {
            start(with: pickerFilter)
            return
        }
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
            DispatchQueue.main.async {
                guard let content, let display = content.displays.first(where: { $0.displayID == displayID }) else {
                    Log.write("record.rebuild_filter_failed error=\(String(describing: error))")
                    self.start(with: pickerFilter)
                    return
                }
                let mine = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
                self.start(with: SCContentFilter(display: display, excludingApplications: mine, exceptingWindows: []))
            }
        }
    }

    /// 検証フック `--record-display <秒>`: picker とカウントダウンを飛ばして、マウスのある画面を録る
    func startForTest(seconds: Double) {
        guard state == .idle else { return }
        targetScreen = .underMouse
        state = .countdown
        begin(SCContentFilter(), isDisplay: true, displayID: targetScreen.displayID)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in self?.stop(reason: "test") }
    }

    private func start(with filter: SCContentFilter) {
        let size = RecordingFormat.outputSize(points: filter.contentRect.size)
        let config = SCStreamConfiguration()
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
            finishPicker()
            state = .idle
            Toast.shared.show("録画を始められませんでした")
            return
        }
        self.stream = stream
        self.output = output
        tmpURL = tmp
        stopReason = "user"
        stream.startCapture { error in
            DispatchQueue.main.async {
                if let error {
                    Log.write("record.start_failed error=\(error)")
                    self.finishPicker()
                    self.cleanup()
                    self.state = .idle
                    Toast.shared.show("録画を始められませんでした")
                    return
                }
                self.startedAt = Date()
                self.state = .recording
                Log.write("record.started size=\(size.width)x\(size.height) fps=\(RecordingFormat.fps)")
            }
        }
    }

    func stop(reason: String) {
        guard state == .recording, let stream else { return }
        stopReason = reason
        state = .stopping
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
        finishPicker()
        cleanup()
        state = .idle
        guard FileManager.default.fileExists(atPath: tmp.path) else {
            Log.write("record.no_file reason=\(reason)")
            Toast.shared.show("録画を保存できませんでした")
            return
        }
        guard let saved = save(tmp) else {
            Toast.shared.show("録画を保存できませんでした: \(Env.saveDir.path)")
            return
        }
        Log.write("record.saved path=\(saved.path) seconds=\(String(format: "%.1f", duration)) reason=\(reason)")
        if reason == "stream_stopped" { Toast.shared.show("録画が途中で止まりました。そこまでを保存しました") }
        onSaved?(saved, screen)
    }

    private func cleanup() {
        stream = nil
        output = nil
        tmpURL = nil
        startedAt = nil
    }

    private func save(_ tmp: URL) -> URL? {
        let fm = FileManager.default
        let dir = Env.saveDir
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let name = FileNaming.uniqueName(stem: FileNaming.stem(for: Date()), ext: "mp4") {
                fm.fileExists(atPath: dir.appendingPathComponent($0).path)
            }
            let dest = dir.appendingPathComponent(name)
            try fm.moveItem(at: tmp, to: dest)
            return dest
        } catch {
            Log.write("record.save_failed error=\(error)")
            return nil
        }
    }
}
