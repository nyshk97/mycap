import AppKit
import AVFoundation
import AVKit

/// 録画のプレビュー（サムネイルの目 / Space）とトリム（はさみ / ⌘E / ダブルクリック）のウィンドウ。
/// トリムは AVPlayerView 標準のトリム UI（CleanShot X と同じ）。「トリム」で `<元>_edited.mp4` をキャッシュに書き、元のサムネイルを置き換える
final class VideoWindowController: NSObject, NSWindowDelegate {
    enum Mode: String { case preview, trim }

    private var window: VideoWindow?
    private var playerView: AVPlayerView?
    private var source: URL?
    private var mode: Mode = .preview
    private var statusObservation: NSKeyValueObservation?
    /// 開く前に前面だったアプリ（閉じたら戻す）
    private var previousApp: NSRunningApplication?
    private var exporting = false
    var isOpen: Bool { window != nil }
    /// トリムして書き出した（元の動画, 書き出した動画, 閉じたあとにフォーカスが戻るアプリ）を受け取る
    var onSaved: ((URL, URL, String?) -> Void)?

    func open(_ url: URL, mode: Mode, activate: Bool = true) {
        if exporting {
            Toast.shared.show("トリムした動画を書き出しています")
            return
        }
        close()
        let asset = AVURLAsset(url: url)
        Task { @MainActor [weak self] in
            let size = await Self.naturalSize(of: asset)
            self?.show(url: url, asset: asset, size: size, mode: mode, activate: activate)
        }
    }

    private static func naturalSize(of asset: AVURLAsset) async -> CGSize {
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let size = try? await track.load(.naturalSize), size.width > 0, size.height > 0 else {
            return CGSize(width: 960, height: 540)
        }
        return size
    }

    private func show(url: URL, asset: AVURLAsset, size: CGSize, mode: Mode, activate: Bool) {
        close()
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = false
        view.showsSharingServiceButton = false

        // 録画は 1x（ピクセル = ポイント）。トリムのバーの分だけ下に余白を取る
        let visible = NSScreen.underMouse.visibleFrame
        let content = Self.initialSize(video: size, visible: visible.size)
        let w = VideoWindow(contentRect: NSRect(origin: .zero, size: content),
                            styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "\(mode == .trim ? "トリム" : "プレビュー") — \(url.lastPathComponent)"
        w.isReleasedWhenClosed = false
        w.level = .floating
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.minSize = NSSize(width: 480, height: 300)
        w.delegate = self
        w.onEscape = { [weak self] in self?.close() }
        w.contentView = view
        w.setFrameOrigin(NSPoint(x: visible.midX - w.frame.width / 2, y: visible.midY - w.frame.height / 2))
        window = w
        playerView = view
        source = url
        self.mode = mode

        if activate {
            previousApp = NSWorkspace.shared.frontmostApplication
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
        } else {
            w.orderFrontRegardless()
        }
        w.makeFirstResponder(view)
        Log.write("video.opened mode=\(mode.rawValue) name=\(url.lastPathComponent) size=\(Int(size.width))x\(Int(size.height)) window=\(Int(content.width))x\(Int(content.height))")

        switch mode {
        case .preview:
            player.play()
        case .trim:
            // トリムの UI は再生の準備ができてからでないと始められない
            statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                guard item.status == .readyToPlay else { return }
                DispatchQueue.main.async { self?.beginTrimming() }
            }
        }
    }

    /// 開いたときの大きさ。動画が原寸で収まる大きさ、収まらなければ画面の 8 割に収まるまで縮める
    static func initialSize(video: CGSize, visible: CGSize) -> NSSize {
        let controls: CGFloat = 80
        let s = min(1, visible.width * 0.8 / video.width, (visible.height * 0.8 - controls) / video.height)
        return NSSize(width: max(480, (video.width * s).rounded()), height: max(300, (video.height * s).rounded() + controls))
    }

    private func beginTrimming() {
        statusObservation = nil
        guard let view = playerView, view.canBeginTrimming else {
            Log.write("video.trim_unavailable")
            return
        }
        view.beginTrimming { [weak self] result in
            guard let self else { return }
            guard result == .okButton else {
                Log.write("video.trim_cancelled")
                close()
                return
            }
            guard let source, let item = view.player?.currentItem else { return }
            let start = item.reversePlaybackEndTime.isValid ? item.reversePlaybackEndTime : .zero
            let end = item.forwardPlaybackEndTime.isValid ? item.forwardPlaybackEndTime : item.duration
            trim(source, start: start, end: end)
        }
    }

    /// 選んだ範囲を書き出してサムネイルを置き換える。範囲が元と同じなら何もせず閉じる。
    /// 検証フック（`--video-trim`）はウィンドウを開かずにここを呼ぶ
    func trim(_ source: URL, start: CMTime, end: CMTime) {
        guard !exporting else { return }
        let asset = AVURLAsset(url: source)
        exporting = true
        Task { @MainActor [weak self] in
            let duration = (try? await asset.load(.duration)) ?? .zero
            let s = CMTimeMaximum(start, .zero)
            let e = CMTimeMinimum(end, duration)
            guard CMTimeCompare(e, s) > 0 else {
                self?.exporting = false
                Log.write("video.trim_empty start=\(s.seconds) end=\(e.seconds)")
                return
            }
            if CMTimeCompare(s, .zero) == 0, CMTimeCompare(e, duration) == 0 {
                self?.exporting = false
                Log.write("video.trim_unchanged duration=\(duration.seconds)")
                if self?.source == source { self?.close() }
                return
            }
            let out = await Self.export(asset, source: source, range: CMTimeRange(start: s, end: e))
            self?.finishTrim(source: source, out: out)
        }
    }

    private static func export(_ asset: AVURLAsset, source: URL, range: CMTimeRange) async -> URL? {
        let dir = source.deletingLastPathComponent()
        let name = FileNaming.uniqueName(stem: FileNaming.editedStem(for: source.lastPathComponent), ext: "mp4") {
            FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path)
        }
        let dest = dir.appendingPathComponent(name)
        // 切り口をキーフレームに丸めないよう、パススルーでなく再エンコードする
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else { return nil }
        session.timeRange = range
        do {
            try await session.export(to: dest, as: .mp4)
        } catch {
            Log.write("video.trim_failed error=\(error)")
            try? FileManager.default.removeItem(at: dest)
            return nil
        }
        CaptureStore.copySourceApp(from: source, to: dest)
        Log.write("video.trimmed name=\(dest.lastPathComponent) start=\(String(format: "%.2f", range.start.seconds)) end=\(String(format: "%.2f", range.end.seconds))")
        return dest
    }

    private func finishTrim(source: URL, out: URL?) {
        exporting = false
        guard let out else {
            Toast.shared.show("トリムした動画を書き出せませんでした")
            return
        }
        let me = ProcessInfo.processInfo.processIdentifier
        let back = previousApp.flatMap { $0.processIdentifier == me ? nil : $0.bundleIdentifier }
        // 開いているのが別の動画に変わっていたら、そちらは閉じない
        if self.source == source { close() }
        onSaved?(source, out, back)
    }

    func close() {
        statusObservation = nil
        guard let window else { return }
        let wasKey = window.isKeyWindow
        playerView?.player?.pause()
        window.delegate = nil
        window.orderOut(nil)
        self.window = nil
        playerView = nil
        source = nil
        Log.write("video.closed mode=\(mode.rawValue)")
        if wasKey, let app = previousApp, app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            app.activate()
        }
        previousApp = nil
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        close()
        return false
    }

    // MARK: - 検証フック用

    func dump() -> String {
        guard let window, let view = playerView else { return "open=false exporting=\(exporting)" }
        let item = view.player?.currentItem
        return "open=true mode=\(mode.rawValue) name=\(source?.lastPathComponent ?? "-") window=\(NSStringFromRect(window.frame)) trimming=\(!view.canBeginTrimming) duration=\(item.map { String(format: "%.2f", $0.duration.seconds) } ?? "-") exporting=\(exporting)"
    }
}

/// Esc で閉じる（トリム中の Esc は AVPlayerView のキャンセルが先に受ける）
final class VideoWindow: NSWindow {
    var onEscape: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "w" {
            onEscape?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
