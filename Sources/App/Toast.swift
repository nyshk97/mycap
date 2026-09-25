import AppKit

/// マウスのある画面の下寄りに短く出す通知。`action` を渡すとクリックで実行できる（システム設定を開く等）
final class Toast {
    static let shared = Toast()

    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?
    private var action: (() -> Void)?

    func show(_ text: String, duration: TimeInterval = 2.5, action: (() -> Void)? = nil) {
        Log.write("toast.shown text=\(text.replacingOccurrences(of: "\n", with: " "))")
        hideWork?.cancel()
        panel?.orderOut(nil)
        self.action = action

        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.preferredMaxLayoutWidth = 420
        let size = label.fittingSize
        let pad = NSSize(width: 20, height: 12)
        let frameSize = NSSize(width: size.width + pad.width * 2, height: size.height + pad.height * 2)

        let content = ClickView(frame: NSRect(origin: .zero, size: frameSize))
        content.onClick = { [weak self] in
            self?.action?()
            self?.hide()
        }
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor(white: 0.1, alpha: 0.88).cgColor
        content.layer?.cornerRadius = 10
        label.frame = NSRect(x: pad.width, y: pad.height, width: size.width, height: size.height)
        content.addSubview(label)

        let screen = NSScreen.underMouse.visibleFrame
        let origin = NSPoint(x: screen.midX - frameSize.width / 2, y: screen.minY + 80)
        let p = NSPanel(contentRect: NSRect(origin: origin, size: frameSize), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false
        p.contentView = content
        p.orderFrontRegardless()
        panel = p

        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (action == nil ? duration : duration * 2), execute: work)
    }

    func hide() {
        hideWork?.cancel()
        panel?.orderOut(nil)
        panel = nil
        action = nil
    }

    private final class ClickView: NSView {
        var onClick: (() -> Void)?
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseUp(with event: NSEvent) { onClick?() }
    }
}
