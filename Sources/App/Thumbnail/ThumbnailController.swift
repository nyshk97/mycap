import AppKit
import AVFoundation

/// 撮影後のサムネイルの束。撮った画面の左下に最新を置き、古いものほど上へ積む。
/// 自動では消えない。最大 5 枚で、あふれたら古いものから閉じる（キャッシュのファイルは 7 日残り、キャプチャ履歴から戻せる）。
/// 出した直後の 1 枚は「待ち受け」になり、マウスを乗せなくてもキーを受ける。クリック・アプリの切り替え・時間切れ等で解く
final class ThumbnailController {
    /// 待ち受けに入る経路と、直後にフォーカスが戻るアプリ（その activate では解かない）
    struct Arm {
        let via: String
        let returnTo: String?
    }

    private struct Item {
        let panel: ThumbnailPanel
        var screenID: CGDirectDisplayID
    }

    /// 先頭が最新
    private var items: [Item] = []
    private var hidden = false

    /// 待ち受け中の 1 枚と、それを解くための見張り
    private weak var armed: ThumbnailPanel?
    private var armReturnTo: String?
    private var armStarted = Date()
    private var armTimer: Timer?
    private var armMonitors: [Any] = []
    private var armObserver: NSObjectProtocol?

    /// サムネイルの「ピン留め」から呼ぶ
    var onPin: ((URL) -> Void)?
    /// サムネイルの「編集」から呼ぶ（録画はトリム）
    var onEdit: ((URL) -> Void)?
    /// 録画のサムネイルの「プレビュー」から呼ぶ
    var onPreview: ((URL) -> Void)?
    /// 編集ウィンドウが開いている間は、待ち受けでキーを取らない（編集の ⌘S が「Downloads へ保存」に化けないように）
    var isEditorOpen: (() -> Bool)?

    init() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.screensChanged() }
    }

    var count: Int { items.count }

    func add(url: URL, screen: NSScreen, arm: Arm? = nil) {
        Self.load(url) { [weak self] image, video in
            self?.add(url: url, image: image, video: video, screen: screen, arm: arm)
        }
    }

    /// サムネイルの画像を読む。録画は先頭のフレームと、長さ・大きさ・音声の有無（非同期。読めなければ呼ばない）
    private static func load(_ url: URL, completion: @escaping (NSImage, VideoInfo?) -> Void) {
        guard url.pathExtension.lowercased() == "mp4" else {
            guard let image = NSImage(contentsOf: url) else {
                Log.write("thumbnail.load_failed path=\(url.path)")
                return
            }
            completion(image, nil)
            return
        }
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        Task { @MainActor in
            do {
                let (cg, _) = try await generator.image(at: .zero)
                let duration = (try? await asset.load(.duration).seconds) ?? 0
                let audio = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
                let bytes = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
                let info = VideoInfo(duration: duration.isFinite ? duration : 0, bytes: bytes, hasAudio: !audio.isEmpty)
                completion(NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)), info)
            } catch {
                Log.write("thumbnail.video_frame_failed path=\(url.path) error=\(error)")
            }
        }
    }

    /// キャプチャ履歴から戻す。同じファイルのサムネイルが出ていたら、それを閉じて最新の位置に出し直す
    func restore(url: URL, screen: NSScreen, arm: Arm? = nil) {
        if let existing = items.first(where: { $0.panel.url == url }) {
            close(existing.panel, reason: "restored_again")
        }
        add(url: url, screen: screen, arm: arm)
    }

    /// 編集（録画はトリム）して保存したとき。元のサムネイルを同じ位置で編集後のものに差し替える（元が閉じていれば最新として出す）
    func replace(_ old: URL, with new: URL, returnTo: String? = nil) {
        let arm = Arm(via: "replace", returnTo: returnTo)
        guard items.contains(where: { $0.panel.url == old }) else {
            Log.write("thumbnail.replace_missing old=\(old.lastPathComponent)")
            add(url: new, screen: .underMouse, arm: arm)
            return
        }
        Self.load(new) { [weak self] image, video in
            self?.swap(old, with: new, image: image, video: video, arm: arm)
        }
    }

    private func swap(_ old: URL, with new: URL, image: NSImage, video: VideoInfo?, arm: Arm) {
        // 録画の読み込みを待つ間に閉じられていたら、最新として出す
        guard let index = items.firstIndex(where: { $0.panel.url == old }) else {
            Log.write("thumbnail.replace_missing old=\(old.lastPathComponent)")
            add(url: new, image: image, video: video, screen: .underMouse, arm: arm)
            return
        }
        let oldPanel = items[index].panel
        let newPanel = makePanel(url: new, image: image, video: video)
        items[index] = Item(panel: newPanel, screenID: items[index].screenID)
        // 新しいパネルがキーを取る前に、古いパネルのキーを手放す
        if armed === oldPanel { disarm(reason: "next") }
        oldPanel.thumbnailView.releaseKeys()
        oldPanel.orderOut(nil)
        relayout(animated: false)
        Log.write("thumbnail.replaced old=\(old.lastPathComponent) new=\(new.lastPathComponent) index=\(index) count=\(items.count)")
        startArm(newPanel, arm)
    }

    private func add(url: URL, image: NSImage, video: VideoInfo?, screen: NSScreen, arm: Arm?) {
        let panel = makePanel(url: url, image: image, video: video)
        items.insert(Item(panel: panel, screenID: screen.displayID), at: 0)
        for old in items.suffix(ThumbnailLayout.overflow(count: items.count)) {
            close(old.panel, reason: "overflow")
        }
        relayout(animated: true, newest: panel)
        Log.write("thumbnail.added name=\(url.lastPathComponent) video=\(video != nil) screen=\(screen.displayID) count=\(items.count)")
        if let arm { startArm(panel, arm) }
    }

    private func makePanel(url: URL, image: NSImage, video: VideoInfo?) -> ThumbnailPanel {
        let size = ThumbnailLayout.panelSize(for: image.size)
        var panel: ThumbnailPanel!
        let actions = ThumbnailView.Actions(
            copy: { [weak self] in
                if video != nil { ImageClipboard.copyFile(url) } else { ImageClipboard.copy(url) }
                Toast.shared.show("Copied", near: panel.frame)
                self?.close(panel, reason: "copied")
            },
            save: { [weak self] in
                guard let saved = CaptureStore.save(url) else {
                    Toast.shared.show("保存できませんでした: \(Env.saveDir.path)", near: panel.frame)
                    return
                }
                Log.write("thumbnail.saved name=\(saved.lastPathComponent) dir=\(saved.deletingLastPathComponent().path)")
                Toast.shared.show("Saved: \(saved.lastPathComponent)", near: panel.frame)
                self?.close(panel, reason: "saved")
            },
            pin: { [weak self] in
                // ピンに出したらサムネイルは要らない
                self?.onPin?(url)
                self?.close(panel, reason: "pinned")
            },
            ocr: { [weak self] in
                // 認識はキャッシュのファイルから非同期に行うので、先に閉じてよい（結果はトーストで出る）
                OCR.recognizeAndCopy(url: url, source: "thumbnail", near: panel.frame)
                self?.close(panel, reason: "ocr")
            },
            edit: { [weak self] in
                // 編集ウィンドウの ⌘S 等を横取りしないように
                self?.disarm(reason: "edit")
                self?.onEdit?(url)
            },
            preview: { [weak self] in
                self?.disarm(reason: "preview")
                self?.onPreview?(url)
            },
            close: { [weak self] in self?.close(panel, reason: "button") },
            draggedOut: { [weak self] in self?.close(panel, reason: "dragged_out") }
        )
        panel = ThumbnailPanel(url: url, image: image, size: size, video: video, actions: actions)
        panel.thumbnailView.onHoverChange = { [weak self, weak panel] entered in
            guard let self, let panel, entered, let current = armed else { return }
            // 乗せたのが待ち受け中の 1 枚ならホバーに引き継ぐ。別の 1 枚なら、そちらがキーを取れるよう先に解く
            disarm(reason: current === panel ? "hover" : "hover_other")
        }
        return panel
    }

    func close(_ panel: ThumbnailPanel, reason: String) {
        guard let index = items.firstIndex(where: { $0.panel === panel }) else { return }
        if armed === panel { disarm(reason: "closed") }
        panel.thumbnailView.releaseKeys()
        panel.orderOut(nil)
        items.remove(at: index)
        Log.write("thumbnail.closed name=\(panel.url.lastPathComponent) reason=\(reason) count=\(items.count)")
        relayout(animated: true)
    }

    func closeAll() {
        let before = items.count
        disarm(reason: "closed")
        for item in items {
            item.panel.thumbnailView.releaseKeys()
            item.panel.orderOut(nil)
        }
        items.removeAll()
        Log.write("thumbnail.closed_all count_before=\(before)")
    }

    /// 撮影中（`screencapture -i` の範囲・ウィンドウ選択中、オールインワンの暗幕）は隠す。ウィンドウとして選べてしまうのを防ぐ。
    /// 隠している間はホバーで取ったキー（Esc 等）も放す（暗幕やカウントダウンの Esc を取られないように）
    func setHidden(_ hide: Bool) {
        hidden = hide
        if hide { disarm(reason: "hidden") }
        for item in items {
            if hide {
                item.panel.thumbnailView.releaseKeys()
                item.panel.orderOut(nil)
            } else {
                item.panel.orderFrontRegardless()
            }
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

    // MARK: - 待ち受け

    /// 出した 1 枚を待ち受けにする。キーを取り合わないよう、ほかのサムネイルのキーと表示を先に手放させる
    private func startArm(_ panel: ThumbnailPanel, _ arm: Arm) {
        disarm(reason: "next")
        for item in items where item.panel !== panel && item.panel.thumbnailView.isHovered {
            item.panel.thumbnailView.setHovered(false)
        }
        armed = panel
        armReturnTo = arm.returnTo
        armStarted = Date()
        let editorOpen = isEditorOpen?() ?? false
        panel.thumbnailView.setArmed(true, grabKeys: Env.armKeys && !editorOpen)
        Log.write("thumbnail.armed name=\(panel.url.lastPathComponent) via=\(arm.via) keys=\(panel.thumbnailView.keyCount) editor_open=\(editorOpen) return_to=\(arm.returnTo ?? "-") seconds=\(Env.armSeconds)")

        armTimer = Timer.scheduledTimer(withTimeInterval: Env.armSeconds, repeats: false) { [weak self] _ in
            self?.disarm(reason: "timeout")
        }
        // マウスの監視はアクセシビリティ許可なしで使える（キーの監視は要る）。移動では解かない
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: clicks, handler: { [weak self] _ in self?.disarm(reason: "click") }) {
            armMonitors.append(m)
        }
        // 自アプリの別ウィンドウ（ピン等）のクリックでも解く。待ち受け中の 1 枚へのクリック（ボタン・持ち出し）では解かない
        if let m = NSEvent.addLocalMonitorForEvents(matching: clicks, handler: { [weak self] event in
            if let self, event.window !== armed { disarm(reason: "click") }
            return event
        }) {
            armMonitors.append(m)
        }
        armObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self else { return }
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let id = app?.bundleIdentifier
            // 撮影・Restore・編集の直後に元のアプリへ戻る activate では解かない
            if let id, id == armReturnTo { return }
            let ms = Int(Date().timeIntervalSince(armStarted) * 1000)
            disarm(reason: "app_switch", detail: "app=\(id ?? "-") after_ms=\(ms)")
        }
    }

    /// 待ち受けを解く（待ち受け中でなければ何もしない）。ホバー中ならキーはホバーの分として残る
    func disarm(reason: String, detail: String? = nil) {
        // 見張りの後片付けは、パネルが先に解放されていても必ず行う
        armTimer?.invalidate()
        armTimer = nil
        armMonitors.forEach(NSEvent.removeMonitor)
        armMonitors.removeAll()
        if let armObserver { NSWorkspace.shared.notificationCenter.removeObserver(armObserver) }
        armObserver = nil
        armReturnTo = nil
        guard let panel = armed else { return }
        armed = nil
        panel.thumbnailView.setArmed(false, grabKeys: false)
        let ms = Int(Date().timeIntervalSince(armStarted) * 1000)
        Log.write("thumbnail.disarmed name=\(panel.url.lastPathComponent) reason=\(reason) ms=\(ms)\(detail.map { " " + $0 } ?? "")")
    }

    // MARK: - 検証フック用

    /// 最新が先頭。`name screen frame hovered armed keys` を返す
    func dump() -> [String] {
        items.map {
            let v = $0.panel.thumbnailView
            return "\($0.panel.url.lastPathComponent) screen=\($0.screenID) frame=\(NSStringFromRect($0.panel.frame)) hovered=\(v.isHovered) armed=\(v.isArmed) keys=\(v.keyCount)\(v.videoState.map { " " + $0 } ?? "")"
        }
    }

    /// 最新のサムネイル（のファイル）。検証フックの `--video-trim` 等
    var newestURL: URL? { items.first?.panel.url }

    /// 最新のサムネイルの「保存」を押す（保存先は MYCAP_SAVE_DIR で差し替えて使う）
    func saveNewest() {
        items.first?.panel.thumbnailView.pressSave()
    }

    /// 最新のサムネイルの「ピン留め」を押す
    func pinNewest() {
        items.first?.panel.thumbnailView.pressPin()
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
