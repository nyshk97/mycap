import AppKit
import CoreMedia
import ScreenCaptureKit

/// スクロールキャプチャ。オールインワン（⌘⇧5）で選んだ範囲を SCStream で流し、ユーザーが手でスクロールするたびに届くコマを
/// `ScrollStitcher` で縦につなぐ。Done（バー・⌘⇧5・メニューバー）で 1 枚の PNG にして `onSaved` に渡す。
/// コマの受け取りは `deliveryQueue`、照合とまとめは `workQueue`（どちらもシリアル）。照合中に届いたコマは最新の 1 枚だけを持っておき、
/// 今の照合が終わったらそれを処理する（スクロールを止めた位置のコマを落とさないため。止まった後は `.idle` しか届かない）
final class ScrollCapturer: NSObject, SCStreamDelegate, SCStreamOutput {
    enum State: String { case idle, starting, capturing, finishing }

    private(set) var state: State = .idle { didSet { onStateChange?() } }
    private(set) var startedAt: Date?
    /// 状態が変わったとき（メニューバーの表示を切り替える）
    var onStateChange: (() -> Void)?
    /// つないだ PNG（一時ファイル）と、撮った画面・撮影元のアプリ
    var onSaved: ((URL, NSScreen, String?) -> Void)?

    private let overlay = ScrollOverlay()
    private let deliveryQueue = DispatchQueue(label: "mycap.scroll.delivery")
    private let workQueue = DispatchQueue(label: "mycap.scroll.work")
    private var stream: SCStream?
    private var screen: NSScreen = .underMouse
    private var app: String?
    private var scale: CGFloat = 2
    /// starting 中に Done / Cancel が来たときの終わり方（startCapture の完了で終える）
    private var pendingEnd: String?

    // workQueue だけで触る
    private var stitcher = ScrollStitcher()
    private var colorSpace: CGColorSpace?
    private var previewRows = 0
    // lock で守る（deliveryQueue と workQueue の受け渡し）
    private let lock = NSLock()
    private var pending: PixelBuffer?
    private var draining = false

    var isActive: Bool { state != .idle }

    /// 範囲（ディスプレイ内の左上原点のポイント）を撮り始める
    func start(screen: NSScreen, rect: CGRect, app: String?) {
        guard state == .idle else {
            Log.write("scroll.start_ignored state=\(state.rawValue)")
            return
        }
        self.screen = screen
        self.app = app
        pendingEnd = nil
        state = .starting
        let displayID = screen.displayID
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
            DispatchQueue.main.async {
                guard let content, let display = content.displays.first(where: { $0.displayID == displayID }) else {
                    Log.write("scroll.no_display id=\(displayID) error=\(String(describing: error))")
                    self.state = .idle
                    Toast.shared.show("スクロールキャプチャを始められませんでした")
                    return
                }
                let mine = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
                self.begin(filter: SCContentFilter(display: display, excludingApplications: mine, exceptingWindows: []), rect: rect)
            }
        }
    }

    private func begin(filter: SCContentFilter, rect: CGRect) {
        scale = CGFloat(filter.pointPixelScale)
        let config = SCStreamConfiguration()
        config.sourceRect = rect
        config.width = Int((rect.width * scale).rounded())
        config.height = Int((rect.height * scale).rounded())
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.captureResolution = .best
        config.showsCursor = false
        config.capturesAudio = false
        config.minimumFrameInterval = CMTime(value: 1, timescale: 15)
        config.queueDepth = 5
        workQueue.sync {
            stitcher = ScrollStitcher(options: .init(ignoreRight: Int((16 * scale).rounded())))
            colorSpace = nil
        }
        lock.withLock { pending = nil }
        colorSpaceTaken = false

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: deliveryQueue)
        } catch {
            Log.write("scroll.add_output_failed error=\(error)")
            state = .idle
            Toast.shared.show("スクロールキャプチャを始められませんでした")
            return
        }
        self.stream = stream
        let screen = screen
        stream.startCapture { error in
            DispatchQueue.main.async {
                if let error {
                    Log.write("scroll.start_failed error=\(error)")
                    self.stream = nil
                    self.state = .idle
                    Toast.shared.show("スクロールキャプチャを始められませんでした")
                    return
                }
                self.startedAt = Date()
                self.state = .capturing
                Log.write("scroll.started rect=\(NSStringFromRect(rect)) px=\(config.width)x\(config.height) scale=\(self.scale)")
                if let reason = self.pendingEnd {
                    self.pendingEnd = nil
                    reason == "cancel" ? self.cancel() : self.finish(reason: reason)
                    return
                }
                let global = AIOLayout.global(rect, screenFrame: screen.frame)
                self.overlay.show(around: global, on: screen, onDone: { self.finish(reason: "done") },
                                  onCancel: { self.cancel() })
                let size = self.overlay.previewSize ?? .zero
                let rows = size.width > 0 ? Int(CGFloat(config.width) * size.height / size.width) : 0
                self.workQueue.async { self.previewRows = rows }
            }
        }
    }

    /// Done: つないだ画像を保存する。`reason` は done（バー）・hotkey・menu_bar・limit・stream_stopped
    func finish(reason: String) {
        switch state {
        case .starting:
            pendingEnd = reason
            Log.write("scroll.end_pending reason=\(reason)")
        case .capturing:
            end(save: true, reason: reason)
        case .idle, .finishing:
            break
        }
    }

    /// Cancel: 何も残さない
    func cancel() {
        switch state {
        case .starting: pendingEnd = "cancel"
        case .capturing: end(save: false, reason: "cancel")
        case .idle, .finishing: break
        }
    }

    private func end(save: Bool, reason: String) {
        state = .finishing
        overlay.hide()
        let stream = stream
        self.stream = nil
        let after = { [self] in
            // 止めた後に積むので、待っている最新の 1 枚まで照合し終えてからまとめる
            workQueue.async { [self] in
                drainPending()
                let result = save ? render() : nil
                let height = stitcher.height, frames = stitcher.frameCount, maxHeight = stitcher.options.maxHeight
                DispatchQueue.main.async { [self] in
                    state = .idle
                    startedAt = nil
                    guard save else {
                        Log.write("scroll.finished reason=cancel height=\(height) frames=\(frames)")
                        return
                    }
                    guard frames > 0 else {
                        Log.write("scroll.finished reason=no_frame height=0 frames=0")
                        Toast.shared.show("画面を受け取れなかったので、何も残しませんでした")
                        return
                    }
                    guard let result else {
                        Log.write("scroll.write_failed")
                        Toast.shared.show("スクロールキャプチャを保存できませんでした")
                        return
                    }
                    Log.write("scroll.finished reason=\(reason) height=\(height) frames=\(frames)")
                    if reason == "stream_stopped" { Toast.shared.show("スクロールキャプチャが途中で止まりました。そこまでを保存しました") }
                    if reason == "limit" { Toast.shared.show("高さの上限（\(maxHeight) px）に達したので保存しました") }
                    onSaved?(result, screen, app)
                }
            }
        }
        guard let stream else { return after() }
        stream.stopCapture { error in
            if let error { Log.write("scroll.stop_error error=\(error)") }
            after()
        }
    }

    /// つないだ画像を PNG の一時ファイルに書く（workQueue で）
    private func render() -> URL? {
        guard let buf = stitcher.compose(), let image = Self.cgImage(buf, colorSpace: colorSpace) else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mycap-\(UUID().uuidString).png")
        return FullScreenCapturer.writePNG(image, scale: scale, to: url) ? url : nil
    }

    // MARK: - コマ

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, let status = SCFrameStatus(rawValue: raw),
              status == .complete || status == .started,
              let pb = sampleBuffer.imageBuffer, let buf = Self.copy(pb) else { return }
        let space = colorSpaceOnce(pb)
        lock.lock()
        pending = buf
        let schedule = !draining
        draining = true
        lock.unlock()
        if schedule {
            workQueue.async { [self] in
                if colorSpace == nil { colorSpace = space }
                drainPending()
            }
        }
    }

    /// 最初のコマの色空間だけを取る（deliveryQueue で。以後は nil を返して取り直さない）
    private var colorSpaceTaken = false
    private func colorSpaceOnce(_ pb: CVImageBuffer) -> CGColorSpace? {
        guard !colorSpaceTaken else { return nil }
        colorSpaceTaken = true
        if let cs = CVImageBufferGetColorSpace(pb)?.takeUnretainedValue() { return cs }
        if let attachments = CVBufferCopyAttachments(pb, .shouldPropagate),
           let cs = CVImageBufferCreateColorSpaceFromAttachments(attachments)?.takeRetainedValue() { return cs }
        return nil
    }

    /// 待っているコマが無くなるまで照合する（workQueue で）
    private func drainPending() {
        while true {
            lock.lock()
            guard let buf = pending else {
                draining = false
                lock.unlock()
                return
            }
            pending = nil
            lock.unlock()
            process(buf)
        }
    }

    private func process(_ buf: PixelBuffer) {
        let r = stitcher.add(buf)
        // 画面が止まっていても .complete のコマが届き続けることがある（実機で 15fps のまま）。変化なしのコマはログに残さない
        if r.accepted || r.dy != 0 { Log.write("scroll.frame kind=\(r.kind.rawValue) dy=\(r.dy) score=\(String(format: "%.2f", r.score)) accepted=\(r.accepted ? 1 : 0) height=\(stitcher.height)") }
        guard r.accepted else { return }
        if r.kind == .limit {
            DispatchQueue.main.async { self.finish(reason: "limit") }
        }
        // プレビューはつなぐたびに描く（間引くと、止めた位置が次につなぐまで出ない）
        let rows = previewRows > 0 ? previewRows : buf.height
        let tail = stitcher.composeTail(rows: rows).flatMap { Self.cgImage($0, colorSpace: colorSpace) }
        let height = stitcher.height
        DispatchQueue.main.async {
            guard self.state == .capturing else { return }
            self.overlay.update(preview: tail, height: height)
        }
    }

    // SCStreamDelegate: ディスプレイを外した・許可が切れた等で SCK 側から止まったとき。そこまでを保存する
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async {
            Log.write("scroll.stream_stopped error=\(error)")
            guard self.state == .capturing else { return }
            self.stream = nil
            self.end(save: true, reason: "stream_stopped")
        }
    }

    // MARK: - 検証フック

    /// `--scroll-frames <dir>`: 連番 PNG（名前順）をコマとして同じ経路に流す（許可が要らない）。書き出しの scale はマウスのある画面
    func stitchFiles(in dir: String) {
        guard state == .idle else { return }
        let urls = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
            .filter { $0.lowercased().hasSuffix(".png") }.sorted()
            .map { URL(fileURLWithPath: dir).appendingPathComponent($0) }
        guard !urls.isEmpty else {
            Log.write("hook.scroll_frames empty dir=\(dir)")
            return
        }
        screen = .underMouse
        scale = screen.backingScaleFactor
        app = CaptureStore.frontmostAppID()
        state = .capturing
        startedAt = Date()
        workQueue.async { [self] in
            stitcher = ScrollStitcher(options: .init(ignoreRight: Int((16 * scale).rounded())))
            colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
            previewRows = 0
            for url in urls {
                guard let buf = Self.load(url) else {
                    Log.write("hook.scroll_frames unreadable=\(url.lastPathComponent)")
                    continue
                }
                process(buf)
                if stitcher.isFull { break }
            }
            DispatchQueue.main.async { self.finish(reason: "test") }
        }
    }

    // MARK: - 変換

    private static func copy(_ pb: CVPixelBuffer) -> PixelBuffer? {
        guard CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_32BGRA else { return nil }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), bpr = CVPixelBufferGetBytesPerRow(pb)
        let data = [UInt8](UnsafeRawBufferPointer(start: base, count: bpr * h))
        return PixelBuffer(width: w, height: h, bytesPerRow: bpr, data: data)
    }

    static func cgImage(_ b: PixelBuffer, colorSpace: CGColorSpace?) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(b.data) as CFData) else { return nil }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        return CGImage(width: b.width, height: b.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: b.bytesPerRow,
                       space: colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info, provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// PNG を BGRA のバッファに描き直す（検証フック用）
    private static func load(_ url: URL) -> PixelBuffer? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        var buf = PixelBuffer(width: image.width, height: image.height)
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        let ok: Bool = buf.data.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: buf.bytesPerRow, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        return ok ? buf : nil
    }
}
