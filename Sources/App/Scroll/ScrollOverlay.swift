import AppKit

/// スクロールキャプチャ中の表示: 範囲の外周の枠、Done / Cancel のバー、つないだ画像のライブプレビュー。
/// どれも mycap のウィンドウなので、撮影のフィルタで外れて写らない。枠とプレビューはマウスを素通しにする（範囲の中でスクロールできるように）
final class ScrollOverlay {
    private let border = RecordingFrame()
    private var barPanel: NSPanel?
    private var previewPanel: NSPanel?
    private var heightLabel: NSTextField?
    private var previewView: ScrollPreviewView?

    /// プレビューの大きさ（ポイント）。出ていなければ nil
    var previewSize: CGSize? { previewView?.bounds.size }

    /// `rect` はグローバル座標（AppKit の左下原点）の範囲、`screen` はその範囲のあるディスプレイ
    func show(around rect: CGRect, on screen: NSScreen, onDone: @escaping () -> Void, onCancel: @escaping () -> Void) {
        hide()
        border.show(around: rect)
        let (bar, label) = Self.makeBar(onDone: onDone, onCancel: onCancel)
        let (origin, barPlacement) = AIOLayout.recordingBarOrigin(selection: rect, bar: bar.frame.size, bounds: screen.frame)
        let barFrame = CGRect(origin: origin, size: bar.frame.size)
        let b = Self.makePanel(frame: barFrame, clickThrough: false)
        b.contentView = bar
        b.orderFrontRegardless()
        barPanel = b
        heightLabel = label

        let (previewFrame, placement) = ScrollLayout.previewFrame(selection: rect, bar: barFrame, bounds: screen.frame)
        let view = ScrollPreviewView(frame: NSRect(origin: .zero, size: previewFrame.size))
        let p = Self.makePanel(frame: previewFrame, clickThrough: true)
        p.contentView = view
        p.orderFrontRegardless()
        previewPanel = p
        previewView = view
        Log.write("scroll.overlay bar=\(barPlacement.rawValue) preview=\(placement.rawValue) frame=\(NSStringFromRect(previewFrame))")
    }

    func update(preview: CGImage?, height: Int) {
        previewView?.image = preview
        heightLabel?.stringValue = Self.heightText(height)
    }

    func hide() {
        border.hide()
        barPanel?.orderOut(nil)
        previewPanel?.orderOut(nil)
        barPanel = nil
        previewPanel = nil
        heightLabel = nil
        previewView = nil
    }

    /// `--scroll-overlay-snapshot`: マウスのある画面で、範囲（左上原点のポイント）を撮っている最中の配置を、画面に出さずに描く。
    /// 暗い灰色がディスプレイ、白い線が範囲。プレビューには縞の見本を描く
    static func snapshot(rect topLeft: CGRect, screen: NSScreen, to path: String) -> Bool {
        let bounds = CGRect(origin: .zero, size: screen.frame.size)
        let rect = AIOLayout.global(topLeft, screenFrame: bounds).intersection(bounds)
        guard !rect.isEmpty else { return false }
        let root = NSView(frame: bounds)
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(white: 0.25, alpha: 1).cgColor
        let sel = NSView(frame: rect)
        sel.wantsLayer = true
        sel.layer?.borderColor = NSColor.white.cgColor
        sel.layer?.borderWidth = 2
        root.addSubview(sel)
        let (bar, label) = makeBar(onDone: {}, onCancel: {})
        label.stringValue = heightText(4321)
        let (origin, _) = AIOLayout.recordingBarOrigin(selection: rect, bar: bar.frame.size, bounds: bounds)
        bar.setFrameOrigin(origin)
        root.addSubview(bar)
        let (pf, placement) = ScrollLayout.previewFrame(selection: rect, bar: bar.frame, bounds: bounds)
        let preview = ScrollPreviewView(frame: pf)
        preview.image = sampleImage(width: Int(rect.width * 2), height: Int(rect.height * 6))
        root.addSubview(preview)
        Log.write("hook.scroll_overlay placement=\(placement.rawValue) bar=\(NSStringFromRect(bar.frame)) preview=\(NSStringFromRect(pf))")
        root.layoutSubtreeIfNeeded()
        guard let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return false }
        root.cacheDisplay(in: root.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: path))) != nil
    }

    // MARK: - 中身

    private static func heightText(_ px: Int) -> String { "↕ \(px) px" }

    private static func makePanel(frame: CGRect, clickThrough: Bool) -> NSPanel {
        let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = !clickThrough
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.ignoresMouseEvents = clickThrough
        p.isReleasedWhenClosed = false
        return p
    }

    private static let barHeight: CGFloat = 34

    private static func makeBar(onDone: @escaping () -> Void, onCancel: @escaping () -> Void) -> (NSView, NSTextField) {
        let label = NSTextField(labelWithString: heightText(0))
        label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        // 高さの桁が増えてもバーの幅が変わらないよう、幅は 5 桁で取っておく
        let labelWidth = ceil((heightText(88888) as NSString).size(withAttributes: [.font: label.font!]).width)
        let cancel = BarButton(title: "Cancel", symbol: "xmark", color: NSColor(white: 0.4, alpha: 1), label: "スクロールキャプチャをやめる", onPress: onCancel)
        let done = BarButton(title: "Done", symbol: "checkmark", color: .systemBlue, label: "スクロールキャプチャを終えて保存する", onPress: onDone)
        let c = cancel.intrinsicContentSize, d = done.intrinsicContentSize

        let pad: CGFloat = 12
        let width = pad + labelWidth + 8 + c.width + 5 + d.width + 5
        let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: barHeight))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor(white: 0.1, alpha: 0.9).cgColor
        content.layer?.cornerRadius = 9
        content.layer?.borderWidth = 1
        content.layer?.borderColor = NSColor(white: 1, alpha: 0.12).cgColor

        let lh = label.fittingSize.height
        label.frame = NSRect(x: pad, y: ((barHeight - lh) / 2).rounded(), width: labelWidth, height: lh)
        var x = pad + labelWidth + 8
        cancel.frame = NSRect(x: x, y: ((barHeight - c.height) / 2).rounded(), width: c.width, height: c.height)
        x += c.width + 5
        done.frame = NSRect(x: x, y: ((barHeight - d.height) / 2).rounded(), width: d.width, height: d.height)
        [label, cancel, done].forEach(content.addSubview)
        return (content, label)
    }

    /// スナップショット用の見本（横縞と、行番号の代わりの濃淡）
    private static func sampleImage(width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for i in stride(from: 0, to: height, by: 48) {
            let t = CGFloat(i) / CGFloat(height)
            ctx.setFillColor(NSColor(calibratedHue: t, saturation: 0.5, brightness: 0.9, alpha: 1).cgColor)
            ctx.fill(CGRect(x: 16, y: i + 10, width: width - 32, height: 28))
        }
        return ctx.makeImage()
    }
}

/// つないだ画像の下端を、幅に合わせて描く（短いうちは上に寄せる）
final class ScrollPreviewView: NSView {
    var image: CGImage? { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(white: 1, alpha: 0.25).cgColor
        layer?.backgroundColor = NSColor(white: 0.1, alpha: 0.85).cgColor
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard let image, image.width > 0, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let h = bounds.width * CGFloat(image.height) / CGFloat(image.width)
        let y = h < bounds.height ? bounds.height - h : 0
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: y, width: bounds.width, height: h))
    }
}
