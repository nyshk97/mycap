import AppKit

/// 最前面に浮かぶ画像 1 枚。全 Space・フルスクリーンの上にも出る。
/// クリックで key になり（アプリはアクティブにしない）、⌘C でコピー・Esc で閉じる。縁と角のドラッグで拡大縮小する
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

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Esc
            close(reason: "esc")
        } else {
            super.keyDown(with: event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods == .command, event.charactersIgnoringModifiers == "c" {
            copyImage()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        close(reason: "esc")
    }
}

private final class PinView: NSView {
    weak var panel: PinPanel?

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
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let panel else { return }
        panel.makeKey()
        if event.clickCount == 2 {
            panel.close(reason: "double_click")
        } else {
            panel.performDrag(with: event)
        }
    }

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
