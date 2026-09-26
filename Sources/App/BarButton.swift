import AppKit

/// 録画・スクロールキャプチャのバーのボタン（色付きの角丸・アイコン＋ラベル）。
/// Capit をアクティブにしないパネルの上なので、1 回目のクリックで押せるよう acceptsFirstMouse を返す
final class BarButton: NSView {
    private let onPress: () -> Void
    private let color: NSColor
    private let label: NSTextField
    private let icon = NSImageView()
    private var hovered = false { didSet { updateBackground() } }
    private var pressed = false { didSet { updateBackground() } }

    init(title: String, symbol: String, color: NSColor, label accessibility: String, onPress: @escaping () -> Void) {
        self.onPress = onPress
        self.color = color
        label = NSTextField(labelWithString: title)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        label.font = .systemFont(ofSize: 12.5, weight: .semibold)
        label.textColor = .white
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .bold))
        icon.contentTintColor = .white
        addSubview(icon)
        addSubview(label)
        setAccessibilityRole(.button)
        setAccessibilityLabel(accessibility)
        toolTip = accessibility
        updateBackground()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 10 + 12 + 5 + label.fittingSize.width + 10, height: 24)
    }

    override func layout() {
        super.layout()
        let l = label.fittingSize
        icon.frame = NSRect(x: 10, y: ((bounds.height - 12) / 2).rounded(), width: 12, height: 12)
        label.frame = NSRect(x: 27, y: ((bounds.height - l.height) / 2).rounded(), width: l.width, height: l.height)
    }

    private func updateBackground() {
        let alpha: CGFloat = pressed ? 0.7 : hovered ? 1 : 0.85
        layer?.backgroundColor = color.withAlphaComponent(alpha).cgColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .cursorUpdate],
                                       owner: self, userInfo: nil))
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func cursorUpdate(with event: NSEvent) { NSCursor.arrow.set() }
    override func mouseDown(with event: NSEvent) { pressed = true }
    override func mouseUp(with event: NSEvent) {
        pressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onPress() }
    }
    override func accessibilityPerformPress() -> Bool {
        onPress()
        return true
    }
}
