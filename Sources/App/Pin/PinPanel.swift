import AppKit

/// 最前面に浮かぶ画像 1 枚。全 Space・フルスクリーンの上にも出る。
/// クリックで key になり（アプリはアクティブにしない）、⌘C でコピーする。縁と角のドラッグで拡大縮小する。
/// うっかり消さないよう、閉じるのはホバーで出る左上の × と右クリックメニューだけ（Esc・ダブルクリックでは閉じない）
final class PinPanel: NSPanel {
    let url: URL
    private let image: NSImage
    private let onClose: () -> Void

    init(url: URL, image: NSImage, frame: NSRect, onClose: @escaping () -> Void) {
        self.url = url
        self.image = image
        self.onClose = onClose
        // 縁と角をつかんでリサイズする（OS 標準の矢印カーソルが出る）。縦横比は固定、実寸の 0.1〜4 倍
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
        contentAspectRatio = image.size
        contentMinSize = NSSize(width: image.size.width * PinLayout.minScale, height: image.size.height * PinLayout.minScale)
        contentMaxSize = NSSize(width: image.size.width * PinLayout.maxScale, height: image.size.height * PinLayout.maxScale)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        let view = PinView(frame: NSRect(origin: .zero, size: frame.size), image: image)
        view.panel = self
        contentView = view
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func close(reason: String) {
        Log.write("pin.close_requested name=\(url.lastPathComponent) reason=\(reason)")
        onClose()
    }

    func copyImage() { ImageClipboard.copy(url) }

    var isCloseButtonShown: Bool { (contentView as? PinView)?.isCloseButtonShown ?? false }
    func setHovered(_ on: Bool) { (contentView as? PinView)?.setHovered(on) }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods == .command, event.charactersIgnoringModifiers == "c" {
            copyImage()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

private final class PinView: NSView {
    weak var panel: PinPanel?
    private var closeButton: CircleButton!

    init(frame: NSRect, image: NSImage) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.masksToBounds = true
        let imageView = NSImageView(frame: bounds)
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.autoresizingMask = [.width, .height]
        addSubview(imageView)

        let d = CircleButton.diameter
        closeButton = CircleButton("xmark", tip: "閉じる") { [weak self] in self?.panel?.close(reason: "button") }
        closeButton.frame.origin = NSPoint(x: 6, y: bounds.height - 6 - d)
        closeButton.autoresizingMask = [.maxXMargin, .minYMargin]
        closeButton.isHidden = true
        addSubview(closeButton)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let panel else { return }
        panel.makeKey()
        panel.performDrag(with: event)
    }

    // MARK: - ホバーで × を出す

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }

    var isCloseButtonShown: Bool { !closeButton.isHidden }
    func setHovered(_ on: Bool) { closeButton.isHidden = !on }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: "コピー", action: #selector(copyImage), keyEquivalent: "").target = self
        menu.addItem(withTitle: "OCR（文字をコピー）", action: #selector(ocr), keyEquivalent: "").target = self
        let opacity = NSMenuItem(title: "透明度", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for percent in [100, 80, 60, 40] {
            let item = NSMenuItem(title: "\(percent)%", action: #selector(setOpacity(_:)), keyEquivalent: "")
            item.target = self
            item.tag = percent
            item.state = Int(((panel?.alphaValue ?? 1) * 100).rounded()) == percent ? .on : .off
            sub.addItem(item)
        }
        opacity.submenu = sub
        menu.addItem(opacity)
        menu.addItem(.separator())
        menu.addItem(withTitle: "閉じる", action: #selector(closePin), keyEquivalent: "").target = self
        return menu
    }

    @objc private func copyImage() { panel?.copyImage() }
    @objc private func ocr() {
        guard let url = panel?.url else { return }
        OCR.recognizeAndCopy(url: url, source: "pin")
    }
    @objc private func setOpacity(_ sender: NSMenuItem) {
        panel?.alphaValue = CGFloat(sender.tag) / 100
        Log.write("pin.opacity value=\(sender.tag)")
    }
    @objc private func closePin() { panel?.close(reason: "menu") }
}
