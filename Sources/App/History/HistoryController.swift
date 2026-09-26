import AppKit
import AVFoundation
import Carbon
import SwiftUI

/// key になれるボーダーレスのパネル。フォーカスを失ったら閉じる
final class HistoryPanel: NSPanel {
    var onResignKey: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }
}

/// キャプチャ履歴（CleanShot X の Capture History 相当）。キャッシュに残っている撮影結果を画面上端の横長パネルに並べ、
/// 選んだものを撮影直後と同じ左下のサムネイルに戻す（Restore）。
///
/// フォーカスは mycast のランチャーと同じモデル: 開くときに前面アプリを覚えて自分をアクティブにし、
/// Esc・ホットキー再押下・Restore で閉じたときだけそのアプリへ戻す（他のアプリのクリックで閉じたときはそのまま）
final class HistoryController {
    enum CloseReason: String {
        case escape, toggle, restored, lostFocus = "lost_focus", hook
    }

    /// Restore したファイルをサムネイルに出す
    /// 3 つ目は閉じたあとにフォーカスが戻るアプリの bundle id（サムネイルの待ち受けがその activate で解けないように）
    var onRestore: ((URL, NSScreen, String?) -> Void)?
    /// 開くとき（サムネイルの待ち受けを解くため。Esc を取り合わないように）
    var onOpen: (() -> Void)?

    private var panel: HistoryPanel?
    private let model = HistoryModel()
    private var previousApp: NSRunningApplication?
    private var keyMonitor: Any?
    private var screenID: CGDirectDisplayID = 0
    private var closing = false

    static let height: CGFloat = 214
    static let margin: CGFloat = 8

    var isOpen: Bool { panel?.isVisible == true }

    init() {
        model.onRestore = { [weak self] item in self?.restore(item) }
    }

    func toggle() {
        if isOpen { close(.toggle) } else { open() }
    }

    /// `activate: false` は検証フック用（フォーカスを奪わずに表示だけする）
    func open(kind: CaptureHistory.Kind = .screenshots, activate: Bool = true) {
        onOpen?()
        if isOpen { close(.hook) }
        let front = NSWorkspace.shared.frontmostApplication
        // フックで開いたとき（activate: false）はフォーカスを動かしていないので、閉じても戻さない
        previousApp = !activate || front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
        model.load(kind: kind)

        let screen = NSScreen.underMouse
        screenID = screen.displayID
        let vf = screen.visibleFrame
        let frame = NSRect(x: vf.minX + Self.margin, y: vf.maxY - Self.margin - Self.height,
                           width: vf.width - Self.margin * 2, height: Self.height)
        let p = makePanel(frame: frame)
        panel = p
        if activate {
            NSApp.activate(ignoringOtherApps: true)
            p.makeKeyAndOrderFront(nil)
            installKeyMonitor()
        } else {
            p.orderFrontRegardless()
        }
        Log.write("history.opened kind=\(kind.rawValue) count=\(model.items.count) activate=\(activate) prev=\(previousApp?.bundleIdentifier ?? "-") screen=\(screenID)")
    }

    func close(_ reason: CloseReason) {
        guard let p = panel, !closing else { return }
        closing = true
        p.onResignKey = nil
        p.orderOut(nil)
        panel = nil
        closing = false
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        model.unload()
        switch reason {
        case .escape, .toggle, .restored:
            if let app = previousApp, !app.isTerminated { app.activate() }
        case .lostFocus, .hook:
            break
        }
        previousApp = nil
        Log.write("history.closed reason=\(reason.rawValue)")
    }

    private func makePanel(frame: NSRect) -> HistoryPanel {
        let p = HistoryPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false

        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: frame.size))
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 22
        effect.layer?.masksToBounds = true
        let host = NSHostingView(rootView: HistoryView(model: model))
        host.frame = effect.bounds
        host.autoresizingMask = [.width, .height]
        effect.addSubview(host)
        p.contentView = effect
        p.onResignKey = { [weak self] in
            // 閉じる途中の orderOut でも呼ばれるので、次のループで判定する
            DispatchQueue.main.async { if self?.panel?.isKeyWindow == false { self?.close(.lostFocus) } }
        }
        return p
    }

    /// パネルが key の間だけ ←→ / Enter / Esc / Tab を取る（ローカルモニタなのでアクセシビリティ許可は要らない）
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            switch Int(event.keyCode) {
            case kVK_LeftArrow: model.moveFocus(by: -1, fromKeyboard: true)
            case kVK_RightArrow: model.moveFocus(by: 1, fromKeyboard: true)
            case kVK_Return, kVK_ANSI_KeypadEnter: model.restoreFocused()
            case kVK_Escape: close(.escape)
            case kVK_Tab: model.switchKind()
            default: return event
            }
            return nil
        }
    }

    private func restore(_ item: HistoryItem) {
        let screen = NSScreen.withID(screenID) ?? .underMouse
        Log.write("history.restored name=\(item.url.lastPathComponent)")
        let back = previousApp?.bundleIdentifier
        close(.restored)
        onRestore?(item.url, screen, back)
    }

    // MARK: - 検証フック用

    func dump() -> String {
        let items = model.items.enumerated().map { i, item in
            "\(item.url.lastPathComponent)|\(CaptureHistory.relativeAge(model.now.timeIntervalSince(item.created)))|app=\(item.appID ?? "-")|icon=\(item.appIcon != nil)|thumb=\(model.thumbs[item.id] != nil)\(i == model.focus ? "|focused" : "")"
        }
        return "open=\(isOpen) kind=\(model.kind.rawValue) count=\(model.items.count) focus=\(model.focus.map(String.init) ?? "-") frame=\(panel.map { NSStringFromRect($0.frame) } ?? "-") items=\(items)"
    }

    func focus(_ index: Int) {
        model.focus = CaptureHistory.moveFocus(index, by: 0, count: model.items.count)
    }

    func switchKind(_ kind: CaptureHistory.Kind) { model.select(kind) }

    func restoreFocused() { model.restoreFocused() }

    func snapshot(to path: String) -> Bool {
        guard let view = panel?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: path))) != nil
    }
}

struct HistoryItem: Identifiable {
    let url: URL
    let created: Date
    let appID: String?
    let appIcon: NSImage?
    var id: String { url.lastPathComponent }
}

final class HistoryModel: ObservableObject {
    @Published private(set) var kind: CaptureHistory.Kind = .screenshots
    @Published private(set) var items: [HistoryItem] = []
    @Published var focus: Int?
    /// キーボードで動かしたときだけスクロールで追う（ホバーで追うと並びが動いてしまう）
    @Published private(set) var scrollTarget: String?
    @Published private(set) var thumbs: [String: NSImage] = [:]
    @Published private(set) var durations: [String: TimeInterval] = [:]
    private(set) var now = Date()
    var onRestore: ((HistoryItem) -> Void)?

    private var entries: [CaptureHistory.Entry] = []
    private var iconCache: [String: NSImage] = [:]
    /// キーボードで動かして並びがスクロールした直後は、カーソルの下に来た項目へのホバーでフォーカスを奪わない
    private var ignoreHoverUntil = Date.distantPast
    private var generation = 0

    func load(kind: CaptureHistory.Kind) {
        now = Date()
        entries = CaptureStore.entries()
        thumbs = [:]
        durations = [:]
        select(kind)
    }

    func unload() {
        generation += 1
        items = []
        thumbs = [:]
        durations = [:]
        focus = nil
    }

    func select(_ kind: CaptureHistory.Kind) {
        self.kind = kind
        items = CaptureHistory.items(entries, kind: kind).map { entry in
            let url = Env.cacheDir.appendingPathComponent(entry.name)
            let app = CaptureStore.sourceApp(of: url)
            return HistoryItem(url: url, created: entry.created, appID: app, appIcon: app.flatMap(icon))
        }
        focus = items.isEmpty ? nil : 0
        scrollTarget = items.first?.id
        loadThumbnails()
    }

    func switchKind() {
        let all = CaptureHistory.Kind.allCases
        select(all[(all.firstIndex(of: kind)! + 1) % all.count])
    }

    func moveFocus(by delta: Int, fromKeyboard: Bool) {
        focus = CaptureHistory.moveFocus(focus, by: delta, count: items.count)
        if fromKeyboard, let focus {
            scrollTarget = items[focus].id
            ignoreHoverUntil = Date().addingTimeInterval(0.4)
        }
    }

    func hover(_ index: Int) {
        guard Date() > ignoreHoverUntil else { return }
        focus = index
    }

    func restoreFocused() {
        guard let focus, items.indices.contains(focus) else { return }
        onRestore?(items[focus])
    }

    func restore(_ index: Int) {
        guard items.indices.contains(index) else { return }
        focus = index
        onRestore?(items[index])
    }

    private func icon(_ bundleID: String) -> NSImage? {
        if let cached = iconCache[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        iconCache[bundleID] = image
        return image
    }

    /// 縮小画像は開くたびに裏で作る（原寸を読み込まない）。閉じたら捨てる
    private func loadThumbnails() {
        generation += 1
        let gen = generation
        for item in items where thumbs[item.id] == nil {
            let id = item.id, url = item.url
            if kind == .videos {
                let asset = AVURLAsset(url: url)
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 480, height: 480)
                generator.generateCGImageAsynchronously(for: .zero) { [weak self] cg, _, _ in
                    guard let cg else { return }
                    DispatchQueue.main.async {
                        guard self?.generation == gen else { return }
                        self?.thumbs[id] = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                    }
                }
                Task { @MainActor [weak self] in
                    guard let d = try? await asset.load(.duration), self?.generation == gen else { return }
                    self?.durations[id] = d.seconds
                }
            } else {
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    let opts = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                kCGImageSourceThumbnailMaxPixelSize: 480,
                                kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary
                    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                          let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts) else { return }
                    DispatchQueue.main.async {
                        guard self?.generation == gen else { return }
                        self?.thumbs[id] = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                    }
                }
            }
        }
    }
}
