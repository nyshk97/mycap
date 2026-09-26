import AppKit

/// 録画中に範囲の右下の外へ出す小さなバー。赤い ● と経過時間、■ 停止ボタン。
/// 置き場が無ければ右上の外 → 範囲の内側の右下（`AIOLayout.recordingBarOrigin`）。mycap のウィンドウは録画のフィルタで外すので、内側でも写らない
final class RecordingBar {
    private var panel: NSPanel?
    private var timeLabel: NSTextField?
    private var timer: Timer?
    private var startedAt = Date()

    /// `rect` はグローバル座標（AppKit の左下原点）の録画範囲、`screen` はその範囲のあるディスプレイ
    func show(around rect: CGRect, on screen: NSScreen, startedAt: Date, onStop: @escaping () -> Void) {
        hide()
        self.startedAt = startedAt
        let (content, label) = Self.makeContent(onStop: onStop)
        let size = content.frame.size
        let (origin, placement) = AIOLayout.recordingBarOrigin(selection: rect, bar: size, bounds: screen.frame)
        let p = NSPanel(contentRect: NSRect(origin: origin, size: size), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.isReleasedWhenClosed = false
        p.contentView = content
        p.orderFrontRegardless()
        panel = p
        timeLabel = label
        updateElapsed()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.updateElapsed() }
        Log.write("record.bar_shown placement=\(placement.rawValue) frame=\(NSStringFromRect(p.frame))")
    }

    func hide() {
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
        panel = nil
        timeLabel = nil
    }

    private func updateElapsed() {
        timeLabel?.stringValue = RecordingFormat.elapsed(Date().timeIntervalSince(startedAt))
    }

    /// `--record-bar-snapshot <png>`: バーだけを画面に出さずに描く（経過時間は 0:12 で固定）
    static func snapshot(to path: String) -> Bool {
        let (view, label) = makeContent(onStop: {})
        label.stringValue = RecordingFormat.elapsed(12)
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: path))) != nil
    }

    // MARK: - 中身

    private static let height: CGFloat = 34

    private static func makeContent(onStop: @escaping () -> Void) -> (NSView, NSTextField) {
        let dot = NSTextField(labelWithString: "●")
        dot.font = .systemFont(ofSize: 11)
        dot.textColor = .systemRed
        let time = NSTextField(labelWithString: RecordingFormat.elapsed(0))
        time.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        time.textColor = .white
        // 経過時間が 9:59 → 10:00 に伸びてもバーの幅が変わらないよう、幅は 0:00:00 で取っておく
        let timeWidth = ceil(("0:00:00" as NSString).size(withAttributes: [.font: time.font!]).width)

        let button = StopButton(onStop: onStop)
        let buttonSize = button.intrinsicContentSize

        let pad: CGFloat = 12
        let dotSize = dot.fittingSize
        let timeHeight = time.fittingSize.height
        let width = pad + dotSize.width + 4 + timeWidth + 8 + buttonSize.width + 5
        let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor(white: 0.1, alpha: 0.9).cgColor
        content.layer?.cornerRadius = 9
        content.layer?.borderWidth = 1
        content.layer?.borderColor = NSColor(white: 1, alpha: 0.12).cgColor

        var x = pad
        dot.frame = NSRect(x: x, y: ((height - dotSize.height) / 2).rounded(), width: dotSize.width, height: dotSize.height)
        x += dotSize.width + 4
        time.frame = NSRect(x: x, y: ((height - timeHeight) / 2).rounded(), width: timeWidth, height: timeHeight)
        x += timeWidth + 8
        button.frame = NSRect(x: x, y: ((height - buttonSize.height) / 2).rounded(), width: buttonSize.width, height: buttonSize.height)
        [dot, time, button].forEach(content.addSubview)
        return (content, time)
    }

    /// ■ 停止。mycap をアクティブにしないパネルの上なので、1 回目のクリックで押せるよう acceptsFirstMouse を返す
    private final class StopButton: NSView {
        private let onStop: () -> Void
        private let label = NSTextField(labelWithString: "停止")
        private let icon = NSImageView()
        private var hovered = false { didSet { updateBackground() } }
        private var pressed = false { didSet { updateBackground() } }

        init(onStop: @escaping () -> Void) {
            self.onStop = onStop
            super.init(frame: .zero)
            wantsLayer = true
            layer?.cornerRadius = 6
            label.font = .systemFont(ofSize: 12.5, weight: .semibold)
            label.textColor = .white
            icon.image = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: "停止")?
                .withSymbolConfiguration(.init(pointSize: 10, weight: .bold))
            icon.contentTintColor = .white
            addSubview(icon)
            addSubview(label)
            setAccessibilityRole(.button)
            setAccessibilityLabel("録画を停止")
            toolTip = "録画を停止"
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
            layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(alpha).cgColor
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
            if bounds.contains(convert(event.locationInWindow, from: nil)) { onStop() }
        }
        override func accessibilityPerformPress() -> Bool {
            onStop()
            return true
        }
    }
}
