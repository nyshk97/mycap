import AppKit

/// 撮影後のサムネイルの束。撮った画面の右下に最新を置き、古いものほど上へ積む。
/// 自動では消えない。最大 5 枚で、あふれたら古いものから閉じる（ファイルは残る）
final class ThumbnailController {
    private struct Item {
        let panel: ThumbnailPanel
        var screenID: CGDirectDisplayID
    }

    /// 先頭が最新
    private var items: [Item] = []
    private var hidden = false

    /// サムネイルの「ピン留め」から呼ぶ
    var onPin: ((URL) -> Void)?

    init() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.screensChanged() }
    }

    var count: Int { items.count }

    func add(url: URL, screen: NSScreen) {
        guard let image = NSImage(contentsOf: url) else {
            Log.write("thumbnail.load_failed path=\(url.path)")
            return
        }
        let size = ThumbnailLayout.panelSize(for: image.size)
        var panel: ThumbnailPanel!
        let actions = ThumbnailView.Actions(
            copy: { ImageClipboard.copy(url) },
            revealInFinder: { NSWorkspace.shared.activateFileViewerSelecting([url]) },
            pin: { [weak self] in
                self?.onPin?(url)
                self?.close(panel, reason: "pinned")
            },
            ocr: { OCR.recognizeAndCopy(url: url, source: "thumbnail") },
            trash: { [weak self] in self?.trash(panel) },
            close: { [weak self] in self?.close(panel, reason: "button") },
            draggedOut: { [weak self] in self?.close(panel, reason: "dragged_out") }
        )
        panel = ThumbnailPanel(url: url, image: image, size: size, actions: actions)
        items.insert(Item(panel: panel, screenID: screen.displayID), at: 0)
        for old in items.suffix(ThumbnailLayout.overflow(count: items.count)) {
            close(old.panel, reason: "overflow")
        }
        relayout(animated: true, newest: panel)
        Log.write("thumbnail.added name=\(url.lastPathComponent) screen=\(screen.displayID) count=\(items.count)")
    }

    func close(_ panel: ThumbnailPanel, reason: String) {
        guard let index = items.firstIndex(where: { $0.panel === panel }) else { return }
        panel.thumbnailView.releaseEsc()
        panel.orderOut(nil)
        items.remove(at: index)
        Log.write("thumbnail.closed name=\(panel.url.lastPathComponent) reason=\(reason) count=\(items.count)")
        relayout(animated: true)
    }

    func closeAll() {
        let before = items.count
        for item in items {
            item.panel.thumbnailView.releaseEsc()
            item.panel.orderOut(nil)
        }
        items.removeAll()
        Log.write("thumbnail.closed_all count_before=\(before)")
    }

    /// 撮影中（`screencapture -i` の範囲・ウィンドウ選択中）は隠す。ウィンドウとして選べてしまうのを防ぐ
    func setHidden(_ hide: Bool) {
        hidden = hide
        for item in items {
            if hide { item.panel.orderOut(nil) } else { item.panel.orderFrontRegardless() }
        }
    }

    private func trash(_ panel: ThumbnailPanel) {
        NSWorkspace.shared.recycle([panel.url]) { _, error in
            Log.write("thumbnail.trashed name=\(panel.url.lastPathComponent) error=\(String(describing: error))")
        }
        close(panel, reason: "trashed")
    }

    /// つないでいた画面が外れたら、そこにあったサムネイルをマウスのある画面へ移す
    private func screensChanged() {
        let alive = Set(NSScreen.screens.map(\.displayID))
        let fallback = NSScreen.underMouse.displayID
        var moved = 0
        for i in items.indices where !alive.contains(items[i].screenID) {
            items[i].screenID = fallback
            moved += 1
        }
        Log.write("thumbnail.screens_changed screens=\(alive.count) moved=\(moved)")
        relayout(animated: false)
    }

    private func relayout(animated: Bool, newest: ThumbnailPanel? = nil) {
        let groups = Dictionary(grouping: items, by: \.screenID)
        for (id, group) in groups {
            guard let screen = NSScreen.withID(id) ?? NSScreen.screens.first else { continue }
            let frames = ThumbnailLayout.frames(visible: screen.visibleFrame, sizes: group.map { $0.panel.frame.size })
            for (item, frame) in zip(group, frames) {
                if item.panel === newest || !animated {
                    item.panel.setFrame(frame, display: true)
                } else {
                    item.panel.setFrame(frame, display: true, animate: true)
                }
                if !hidden { item.panel.orderFrontRegardless() }
            }
        }
    }

    // MARK: - 検証フック用

    /// 最新が先頭。`name screen frame hovered` を返す
    func dump() -> [String] {
        items.map { "\($0.panel.url.lastPathComponent) screen=\($0.screenID) frame=\(NSStringFromRect($0.panel.frame)) hovered=\($0.panel.thumbnailView.isHovered)" }
    }

    func hoverNewest(_ on: Bool) {
        items.first?.panel.thumbnailView.setHovered(on, grabEsc: false)
    }

    /// 最新のサムネイルの中身をプロセス内描画で PNG にする（画面収録の許可は要らない）
    func snapshotNewest(to path: String) -> Bool {
        guard let view = items.first?.panel.thumbnailView else { return false }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: path))) != nil
    }
}
