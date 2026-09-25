import AppKit

/// デスクトップアイコンを隠す。アイコンより上・通常のウィンドウより下の層に、壁紙を表示したウィンドウを各画面へ敷く
/// （Finder の CreateDesktop を書き換える方式は Finder が再起動するので採らない）。
/// オン／オフは UserDefaults に覚え、起動時に戻す
final class DesktopCover {
    private static let defaultsKey = "hideDesktopIcons"
    private var windows: [CGDirectDisplayID: NSWindow] = [:]

    private(set) var isOn: Bool {
        get { UserDefaults.standard.bool(forKey: Self.defaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.defaultsKey) }
    }

    /// 全画面の撮影（SCK）で自分のウィンドウを外すとき、これだけは写す
    var windowNumbers: [Int] { windows.values.map(\.windowNumber) }

    init() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.rebuild(reason: "screens_changed") }
        // Space ごとに壁紙が違うことがあるので、Space を移ったら敷き直す
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.rebuild(reason: "space_changed") }
        rebuild(reason: "launch")
    }

    func toggle() {
        isOn.toggle()
        rebuild(reason: "toggle")
    }

    private func rebuild(reason: String) {
        windows.values.forEach { $0.orderOut(nil) }
        windows.removeAll()
        guard isOn else {
            Log.write("desktop_cover.off reason=\(reason)")
            return
        }
        var fallbacks = 0
        for screen in NSScreen.screens {
            let (image, fallback) = wallpaper(for: screen)
            if fallback { fallbacks += 1 }
            let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            w.ignoresMouseEvents = true
            w.isReleasedWhenClosed = false
            w.hasShadow = false
            w.backgroundColor = image == nil ? .windowBackgroundColor : .black
            let (scaling, clip) = screenScaling(screen)
            w.contentView = WallpaperView(image: image, scaling: scaling, allowClipping: clip)
            w.setFrame(screen.frame, display: true)
            w.orderFrontRegardless()
            windows[screen.displayID] = w
        }
        Log.write("desktop_cover.on reason=\(reason) screens=\(windows.count) fallback=\(fallbacks)")
    }

    /// 壁紙を静止画として読む。読めない（動く壁紙など）ときは nil（単色で塗る）
    private func wallpaper(for screen: NSScreen) -> (NSImage?, Bool) {
        guard let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return (nil, true) }
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        guard !isDir.boolValue, let image = NSImage(contentsOf: url), image.isValid else {
            Log.write("desktop_cover.wallpaper_unreadable path=\(url.path)")
            return (nil, true)
        }
        return (image, false)
    }

    /// 壁紙の合わせ方。「画面いっぱい」は proportionallyUpOrDown ＋ 切り取り可、「画面に合わせる」は切り取り不可
    private func screenScaling(_ screen: NSScreen) -> (NSImageScaling, Bool) {
        let options = NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:]
        let scaling = (options[.imageScaling] as? NSNumber).flatMap { NSImageScaling(rawValue: $0.uintValue) }
        let clip = (options[.allowClipping] as? NSNumber)?.boolValue ?? true
        return (scaling ?? .scaleProportionallyUpOrDown, clip)
    }
}

/// 壁紙の描画。「画面いっぱい（切り取り）」は AppKit の NSImageView に無いので自前で描く
private final class WallpaperView: NSView {
    private let image: NSImage?
    private let scaling: NSImageScaling
    private let allowClipping: Bool

    init(image: NSImage?, scaling: NSImageScaling, allowClipping: Bool) {
        self.image = image
        self.scaling = scaling
        self.allowClipping = allowClipping
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard let image, image.size.width > 0, image.size.height > 0 else {
            NSColor.windowBackgroundColor.setFill()
            bounds.fill()
            return
        }
        NSColor.black.setFill()
        bounds.fill()
        let s = image.size
        let rect: NSRect
        switch scaling {
        case .scaleAxesIndependently:
            rect = bounds
        case .scaleNone:
            rect = NSRect(x: bounds.midX - s.width / 2, y: bounds.midY - s.height / 2, width: s.width, height: s.height)
        default:
            // 切り取り可なら画面を埋める（画面いっぱい）、不可なら全体が収まるように（画面に合わせる）
            let kx = bounds.width / s.width, ky = bounds.height / s.height
            let k = allowClipping ? max(kx, ky) : min(kx, ky)
            let size = NSSize(width: s.width * k, height: s.height * k)
            rect = NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
        }
        image.draw(in: rect)
    }
}
