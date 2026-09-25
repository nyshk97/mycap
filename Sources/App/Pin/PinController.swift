import AppKit

/// 撮った画像を最前面に浮かせる。複数枚を同時に出せる
final class PinController {
    private var panels: [PinPanel] = []

    var count: Int { panels.count }

    func pin(url: URL) {
        guard let image = NSImage(contentsOf: url) else {
            Log.write("pin.load_failed path=\(url.path)")
            return
        }
        let screen = NSScreen.underMouse
        let frame = PinLayout.initialFrame(image: image.size, visible: screen.visibleFrame)
        var panel: PinPanel!
        panel = PinPanel(url: url, image: image, frame: frame, onClose: { [weak self] in self?.close(panel) })
        panels.append(panel)
        panel.orderFrontRegardless()
        Log.write("pin.opened name=\(url.lastPathComponent) screen=\(screen.displayID) frame=\(NSStringFromRect(frame)) count=\(panels.count)")
    }

    func close(_ panel: PinPanel) {
        guard let i = panels.firstIndex(where: { $0 === panel }) else { return }
        panel.orderOut(nil)
        panels.remove(at: i)
        Log.write("pin.closed name=\(panel.url.lastPathComponent) count=\(panels.count)")
    }

    func closeAll() {
        panels.forEach { $0.orderOut(nil) }
        Log.write("pin.closed_all count_before=\(panels.count)")
        panels.removeAll()
    }

    // MARK: - 検証フック用

    func dump() -> [String] {
        panels.map { "\($0.url.lastPathComponent) frame=\(NSStringFromRect($0.frame)) alpha=\($0.alphaValue)" }
    }
}
