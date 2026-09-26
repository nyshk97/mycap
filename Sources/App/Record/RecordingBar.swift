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

        let button = BarButton(title: "停止", symbol: "stop.fill", color: .systemRed, label: "録画を停止", onPress: onStop)
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
}
