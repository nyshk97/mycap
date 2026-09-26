import AppKit

/// 録画中に範囲の外側へ出す枠。範囲（`sourceRect`）の外に描くので、ScreenCaptureKit のアプリ除外が効かなくても写らない。
/// クリックは素通しする
final class RecordingFrame {
    private static let width: CGFloat = 2
    private static let gap: CGFloat = 1
    private var panel: NSPanel?

    /// `rect` はグローバル座標（AppKit の左下原点）の録画範囲
    func show(around rect: CGRect) {
        hide()
        let inset = Self.width + Self.gap
        let frame = rect.insetBy(dx: -inset, dy: -inset)
        let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.ignoresMouseEvents = true
        p.isReleasedWhenClosed = false
        let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        let border = CAShapeLayer()
        let ring = NSRect(origin: .zero, size: frame.size).insetBy(dx: Self.width / 2, dy: Self.width / 2)
        border.path = CGPath(rect: ring, transform: nil)
        border.fillColor = nil
        border.strokeColor = NSColor.systemRed.withAlphaComponent(0.9).cgColor
        border.lineWidth = Self.width
        view.layer?.addSublayer(border)
        p.contentView = view
        p.orderFrontRegardless()
        panel = p
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}
