import AppKit
import AVFoundation
import ScreenCaptureKit

/// 動画録画。オールインワン（⌘⇧5）で選んだ範囲を、3 秒のカウントダウンのあと
/// SCRecordingOutput で mp4（1x・H.264・30fps・カーソルあり）に書く。音声（マイク・システム音）は `RecordingAudio` のとおり。
/// 両方入れて別トラックに書かれたら、停止後に `AudioMixer` で 1 トラックへ混ぜ直す。
/// 録画中は範囲の外側に枠と停止バーを出す（mycap のウィンドウはフィルタで外すうえ、枠は範囲の外なので写らない）
final class Recorder: NSObject, SCStreamDelegate, SCRecordingOutputDelegate {
    /// countdown はマイクの許可の返事を待つ間も含む。finishing は停止後に音声を混ぜ直している間
    enum State: String { case idle, countdown, recording, stopping, finishing }

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
    /// マイクの許可の返事を待っている録画の開始。⌘⇧5 で取り消すと nil にし、返事が来ても始めない
    private var pendingStart: UUID?
    /// この録画に実際に入れた音声（許可が無ければマイクは外れる）
    private var audio = RecordingAudio(mic: false, system: false)

    /// ⌘⇧5 の振り分け（`AIOController`）から: カウントダウン中ならキャンセル、録画中なら停止
    func toggle() {
        switch state {
        case .idle: Log.write("record.toggle_ignored state=idle")
        case .countdown:
            if pendingStart != nil {
                pendingStart = nil
                state = .idle
                Log.write("record.cancelled_while_mic_request")
            } else {
                countdown.cancel()
            }
        case .recording: stop(reason: "user")
        case .stopping, .finishing: break
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
        resolveAudio { [weak self] in
            self?.countdown.start(seconds: 3, on: screen, finish: { [weak self] in
                self?.begin(screen: screen, rect: rect)
            }, cancel: { [weak self] in
                self?.state = .idle
            })
        }
    }

    /// 音声の設定を読み、マイク ON なら許可を確かめてから `then` を呼ぶ（呼ぶ側は state を .countdown にしておく）。
    /// 返事を待つ間に ⌘⇧5 で取り消されたら呼ばない
    private func resolveAudio(then: @escaping () -> Void) {
        let token = UUID()
        pendingStart = token
        RecordingAudio.resolve(RecordingAudio.load()) { [weak self] audio in
            guard let self, pendingStart == token, state == .countdown else { return }
            pendingStart = nil
            self.audio = audio
            then()
        }
    }

    /// 検証フック `--record-display <秒>` / `--aio-record x y w h <秒>`: カウントダウンを飛ばして、マウスのある画面（か、その範囲）を録る
    func startForTest(seconds: Double, rect: CGRect? = nil) {
        guard state == .idle else { return }
        targetScreen = .underMouse
        sourceApp = CaptureStore.frontmostAppID()
        state = .countdown
        resolveAudio { [weak self] in
            guard let self else { return }
            begin(screen: targetScreen, rect: rect)
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in self?.stop(reason: "test") }
        }
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
        config.capturesAudio = audio.system
        config.excludesCurrentProcessAudio = true
        config.captureMicrophone = audio.mic

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
                // システム音からは mycap 自身の音を除いている（excludesCurrentProcessAudio）ので、開始音は動画に入らない
                Sounds.playRecordStart()
                if let rect {
                    let global = AIOLayout.global(rect, screenFrame: screen.frame)
                    self.frame.show(around: global)
                    self.bar.show(around: global, on: screen, startedAt: self.startedAt ?? Date()) { [weak self] in
                        self?.stop(reason: "bar")
                    }
                }
                Log.write("record.started size=\(size.width)x\(size.height) fps=\(RecordingFormat.fps) mic=\(self.audio.mic) system=\(self.audio.system) rect=\(rect.map { NSStringFromRect($0) } ?? "display")")
            }
        }
    }

    func stop(reason: String) {
        guard state == .recording, let stream else { return }
        stopReason = reason
        state = .stopping
        Sounds.playRecordStop()
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
                Sounds.playRecordStop()
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
        guard FileManager.default.fileExists(atPath: tmp.path) else {
            state = .idle
            Log.write("record.no_file reason=\(reason)")
            Toast.shared.show("録画を保存できませんでした")
            return
        }
        // 混ぜ直す間は finishing（⌘⇧5 は受けず、停止のタイムアウトからも再び入らない）
        state = .finishing
        AudioMixer.audioTrackCount(tmp) { [weak self] tracks in
            guard let self else { return }
            guard RecordingFormat.needsAudioMix(audioTracks: tracks) else {
                return keep(tmp, tracks: tracks, duration: duration, reason: reason, screen: screen)
            }
            let t0 = Date()
            var settled = false
            // 片方の入力が止まって返ってこないときも録画を失わない。3 分で約 1 秒なので、長さの半分（最低 15 秒）で見切る
            DispatchQueue.main.asyncAfter(deadline: .now() + max(15, duration / 2)) { [weak self] in
                guard let self, !settled else { return }
                settled = true
                Log.write("record.audio_mix_failed reason=timeout")
                keep(tmp, tracks: tracks, duration: duration, reason: reason, screen: screen)
            }
            AudioMixer.mix(tmp) { [weak self] mixed in
                guard !settled else {
                    if let mixed { try? FileManager.default.removeItem(at: mixed) }
                    return
                }
                settled = true
                guard let self else { return }
                let ms = Int(Date().timeIntervalSince(t0) * 1000)
                if let mixed {
                    Log.write("record.audio_mixed tracks=\(tracks) ms=\(ms)")
                    try? FileManager.default.removeItem(at: tmp)
                    keep(mixed, tracks: 1, duration: duration, reason: reason, screen: screen)
                } else {
                    // 失敗したら 2 トラックのまま置く（録画を失わない）
                    keep(tmp, tracks: tracks, duration: duration, reason: reason, screen: screen)
                }
            }
        }
    }

    private func keep(_ file: URL, tracks: Int, duration: TimeInterval, reason: String, screen: NSScreen) {
        state = .idle
        guard let saved = CaptureStore.keep(file, app: sourceApp) else {
            Toast.shared.show("録画を置けませんでした: \(Env.cacheDir.path)")
            return
        }
        Log.write("record.captured path=\(saved.path) seconds=\(String(format: "%.1f", duration)) reason=\(reason) audio_tracks=\(tracks)")
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
