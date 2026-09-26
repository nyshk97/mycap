import AppKit
import Carbon

/// 録画・タイマー撮影の前の 3 秒のカウントダウン。画面中央に大きく出す。Esc（またはホットキーの再押下）でキャンセルできる。
/// 録画・撮影はカウントダウンを閉じてから始めるので、この表示は写らない
final class Countdown {
    /// ログの接頭辞（`record` / `timer`）
    private let logPrefix: String

    init(logPrefix: String) {
        self.logPrefix = logPrefix
    }

    private var panel: NSPanel?
    private var label: NSTextField?
    private var timer: Timer?
    private var escToken: UInt32?
    private var onFinish: (() -> Void)?
    private var onCancel: (() -> Void)?

    var isRunning: Bool { panel != nil }

    func start(seconds: Int, on screen: NSScreen, finish: @escaping () -> Void, cancel: @escaping () -> Void) {
        stop()
        onFinish = finish
        onCancel = cancel
        let size = NSSize(width: 180, height: 180)
        let frame = NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.midY - size.height / 2,
                           width: size.width, height: size.height)
        let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .screenSaver
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.ignoresMouseEvents = true
        p.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(origin: .zero, size: size))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.82).cgColor
        content.layer?.cornerRadius = 28
        let l = NSTextField(labelWithString: "\(seconds)")
        l.font = .monospacedDigitSystemFont(ofSize: 96, weight: .semibold)
        l.textColor = .white
        l.alignment = .center
        l.frame = NSRect(x: 0, y: 30, width: size.width, height: 120)
        content.addSubview(l)
        let hint = NSTextField(labelWithString: "Esc でキャンセル")
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = NSColor(white: 1, alpha: 0.6)
        hint.alignment = .center
        hint.frame = NSRect(x: 0, y: 14, width: size.width, height: 18)
        content.addSubview(hint)
        p.contentView = content
        p.orderFrontRegardless()
        panel = p
        label = l
        escToken = HotKeyCenter.shared.registerToken(keyCode: kVK_Escape, modifiers: 0) { [weak self] in
            self?.cancel()
        }.id

        var remaining = seconds
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            remaining -= 1
            if remaining <= 0 {
                let done = self?.onFinish
                self?.stop()
                done?()
            } else {
                self?.label?.stringValue = "\(remaining)"
            }
        }
        Log.write("\(logPrefix).countdown_started seconds=\(seconds) screen=\(screen.displayID)")
    }

    func cancel() {
        guard isRunning else { return }
        let cancelled = onCancel
        stop()
        Log.write("\(logPrefix).countdown_cancelled")
        cancelled?()
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        if let token = escToken { HotKeyCenter.shared.unregister(token) }
        escToken = nil
        panel?.orderOut(nil)
        panel = nil
        label = nil
        onFinish = nil
        onCancel = nil
    }
}
