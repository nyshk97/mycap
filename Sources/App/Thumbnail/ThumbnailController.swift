import AppKit
import AVFoundation

/// 撮影後のサムネイルの束。撮った画面の左下に最新を置き、古いものほど上へ積む。
/// 自動では消えない。最大 5 枚で、あふれたら古いものから閉じる（キャッシュのファイルは 24 時間残る）
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
    /// サムネイルの「整形」から呼ぶ
    var onStyle: ((URL) -> Void)?

    init() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.screensChanged() }
    }

    var count: Int { items.count }

    func add(url: URL, screen: NSScreen) {
        if url.pathExtension.lowercased() == "mp4" {
            // 動画は先頭のフレームをサムネイルにする
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.generateCGImageAsynchronously(for: .zero) { [weak self] cg, _, error in
                DispatchQueue.main.async {
                    guard let cg else {
                        Log.write("thumbnail.video_frame_failed path=\(url.path) error=\(String(describing: error))")
                        return
                    }
                    self?.add(url: url, image: NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)),
                              isVideo: true, screen: screen)
                }
            }
            return
        }
        guard let image = NSImage(contentsOf: url) else {
            Log.write("thumbnail.load_failed path=\(url.path)")
            return
        }
        add(url: url, image: image, isVideo: false, screen: screen)
    }

    private func add(url: URL, image: NSImage, isVideo: Bool, screen: NSScreen) {
        let size = ThumbnailLayout.panelSize(for: image.size)
        var panel: ThumbnailPanel!
        let actions = ThumbnailView.Actions(
            copy: { [weak self] in
                ImageClipboard.copy(url)
                Toast.shared.show("コピーしました", near: panel.frame)
                self?.close(panel, reason: "copied")
            },
            save: { [weak self] in
                guard let saved = CaptureStore.save(url) else {
                    Toast.shared.show("保存できませんでした: \(Env.saveDir.path)", near: panel.frame)
                    return
                }
                Log.write("thumbnail.saved name=\(saved.lastPathComponent) dir=\(saved.deletingLastPathComponent().path)")
                Toast.shared.show("保存しました: \(saved.lastPathComponent)", near: panel.frame)
                self?.close(panel, reason: "saved")
            },
            pin: { [weak self] in self?.onPin?(url) },
            ocr: { [weak self] in
                // 認識はキャッシュのファイルから非同期に行うので、先に閉じてよい（結果はトーストで出る）
                OCR.recognizeAndCopy(url: url, source: "thumbnail", near: panel.frame)
                self?.close(panel, reason: "ocr")
            },
            style: { [weak self] in self?.onStyle?(url) },
            close: { [weak self] in self?.close(panel, reason: "button") },
            draggedOut: { [weak self] in self?.close(panel, reason: "dragged_out") }
        )
        panel = ThumbnailPanel(url: url, image: image, size: size, isVideo: isVideo, actions: actions)
        items.insert(Item(panel: panel, screenID: screen.displayID), at: 0)
        for old in items.suffix(ThumbnailLayout.overflow(count: items.count)) {
            close(old.panel, reason: "overflow")
        }
        relayout(animated: true, newest: panel)
        Log.write("thumbnail.added name=\(url.lastPathComponent) video=\(isVideo) screen=\(screen.displayID) count=\(items.count)")
    }

    func close(_ panel: ThumbnailPanel, reason: String) {
        guard let index = items.firstIndex(where: { $0.panel === panel }) else { return }
        panel.thumbnailView.releaseKeys()
        panel.orderOut(nil)
        items.remove(at: index)
        Log.write("thumbnail.closed name=\(panel.url.lastPathComponent) reason=\(reason) count=\(items.count)")
        relayout(animated: true)
    }

    func closeAll() {
        let before = items.count
        for item in items {
            item.panel.thumbnailView.releaseKeys()
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

    /// 最新のサムネイルの「保存」を押す（保存先は MYCAP_SAVE_DIR で差し替えて使う）
    func saveNewest() {
        items.first?.panel.thumbnailView.pressSave()
    }

    func hoverNewest(_ on: Bool) {
        items.first?.panel.thumbnailView.setHovered(on, grabKeys: false)
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
