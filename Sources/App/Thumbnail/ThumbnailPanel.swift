import AppKit
import Carbon
import CoreImage

/// 撮影後に画面の隅へ出るサムネイル 1 枚。アプリをアクティブにしない NSPanel で、全 Space・フルスクリーンの上にも出る
final class ThumbnailPanel: NSPanel {
    let url: URL
    let thumbnailView: ThumbnailView

    init(url: URL, image: NSImage, size: NSSize, isVideo: Bool, actions: ThumbnailView.Actions) {
        self.url = url
        thumbnailView = ThumbnailView(frame: NSRect(origin: .zero, size: size), url: url, image: image, isVideo: isVideo, actions: actions)
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        // .moveToActiveSpace と .canJoinAllSpaces を同時に指定すると例外になる（swift-projects.md）
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .utilityWindow
        contentView = thumbnailView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// サムネイルの中身。画像・ホバー時のボタン・ドラッグでの持ち出し
final class ThumbnailView: NSView, NSDraggingSource {
    struct Actions {
        var copy: () -> Void
        /// ~/Downloads へ保存し、保存先を返す（失敗なら nil）
        var save: () -> URL?
        /// 保存したファイルを Finder で表示する
        var revealInFinder: (URL) -> Void
        var pin: () -> Void
        var ocr: () -> Void
        var style: () -> Void
        var close: () -> Void
        /// ドラッグで持ち出せたとき（ドロップ先が受け取ったとき）
        var draggedOut: () -> Void
    }

    private let url: URL
    private let image: NSImage
    private let actions: Actions
    /// 動画はコピー・ピン・OCR・整形を出さない（保存・閉じる・ドラッグだけ）
    private let isVideo: Bool
    private let overlay = NSView()
    private var mouseDownPoint: NSPoint?
    private var escToken: UInt32?
    private(set) var isHovered = false
    /// 「保存」を押して ~/Downloads に書いた先。保存後は Save が「Finder」（Finder で表示）に変わる
    private(set) var savedURL: URL?
    private var saveButton: PillButton?

    init(frame: NSRect, url: URL, image: NSImage, isVideo: Bool, actions: Actions) {
        self.url = url
        self.image = image
        self.isVideo = isVideo
        self.actions = actions
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor(white: 0.12, alpha: 0.92).cgColor
        layer?.borderColor = NSColor(white: 1, alpha: 0.18).cgColor
        layer?.borderWidth = 1

        let imageView = NSImageView(frame: bounds)
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.autoresizingMask = [.width, .height]
        addSubview(imageView)

        // ホバー中は CleanShot X と同じく、画像をぼかして暗くした上にボタンを出す
        overlay.frame = bounds
        overlay.autoresizingMask = [.width, .height]
        overlay.wantsLayer = true
        overlay.isHidden = true
        let blurred = NSImageView(frame: bounds)
        blurred.image = Self.blurred(image, displayWidth: frame.width)
        blurred.imageScaling = .scaleProportionallyUpOrDown
        blurred.autoresizingMask = [.width, .height]
        overlay.addSubview(blurred)
        let dim = NSView(frame: bounds)
        dim.wantsLayer = true
        dim.layer?.backgroundColor = NSColor(white: 0, alpha: 0.45).cgColor
        dim.autoresizingMask = [.width, .height]
        overlay.addSubview(dim)
        addSubview(overlay)
        buildButtons()
        if isVideo { addVideoBadge() }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 四隅に丸ボタン（左上 閉じる・右上 ピン・左下 整形・右下 OCR）、中央に Copy / Save。動画は閉じると Save だけ
    private func buildButtons() {
        let inset: CGFloat = 7
        let d = CircleButton.diameter
        func corner(_ button: NSButton, left: Bool, top: Bool) {
            button.frame.origin = NSPoint(x: left ? inset : bounds.width - inset - d,
                                          y: top ? bounds.height - inset - d : inset)
            button.autoresizingMask = [left ? .maxXMargin : .minXMargin, top ? .minYMargin : .maxYMargin]
            overlay.addSubview(button)
        }
        corner(CircleButton("xmark", tip: "閉じる（Esc）") { [weak self] in self?.actions.close() }, left: true, top: true)
        if !isVideo {
            corner(CircleButton("pin.fill", tip: "ピン留め") { [weak self] in self?.actions.pin() }, left: false, top: true)
            corner(CircleButton("pencil", tip: "整形（背景と余白）") { [weak self] in self?.actions.style() }, left: true, top: false)
            corner(CircleButton("text.viewfinder", tip: "OCR（文字をコピー）") { [weak self] in self?.actions.ocr() }, left: false, top: false)
        }

        let save = PillButton("Save", tip: "保存（~/Downloads）") { [weak self] in self?.pressSave() }
        saveButton = save
        let pills = isVideo ? [save] : [PillButton("Copy", tip: "コピー") { [weak self] in self?.actions.copy() }, save]
        let column = NSStackView(views: pills)
        column.orientation = .vertical
        column.spacing = 6
        column.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(column)
        NSLayoutConstraint.activate([
            column.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            column.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
        ])
    }

    /// ホバー時の背景。表示の大きさで 6pt 相当のぼかしになるよう、画像のピクセル幅に合わせて半径を決める
    private static func blurred(_ image: NSImage, displayWidth: CGFloat) -> NSImage? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let input = CIImage(cgImage: cg)
        let radius = 6 * CGFloat(cg.width) / max(displayWidth, 1)
        guard let filter = CIFilter(name: "CIGaussianBlur") else { return nil }
        filter.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
        filter.setValue(radius, forKey: kCIInputRadiusKey)
        guard let output = filter.outputImage?.cropped(to: input.extent),
              let out = CIContext().createCGImage(output, from: input.extent) else { return nil }
        return NSImage(cgImage: out, size: image.size)
    }

    /// 動画だと分かる印（左下の再生マーク）
    private func addVideoBadge() {
        let badge = NSImageView(frame: NSRect(x: 8, y: 8, width: 22, height: 22))
        badge.image = NSImage(systemSymbolName: "play.circle.fill", accessibilityDescription: "動画")?
            .withSymbolConfiguration(.init(pointSize: 18, weight: .semibold))
        badge.contentTintColor = .white
        addSubview(badge, positioned: .below, relativeTo: overlay)
    }

    /// 未保存なら保存して、ボタンを「Finder で表示」に変える。保存済みなら Finder で表示する
    func pressSave() {
        if let savedURL {
            actions.revealInFinder(savedURL)
            return
        }
        guard let saved = actions.save() else { return }
        savedURL = saved
        saveButton?.setLabel("Finder")
        saveButton?.toolTip = "Finder で表示（\(saved.lastPathComponent)）"
    }

    // MARK: - ホバー

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }

    /// ホバー中だけ Esc をホットキーとして取る（キー監視のアクセシビリティ許可を要らなくするため）。
    /// `grabEsc: false` は検証フックでボタンの見た目だけ撮るとき
    func setHovered(_ hovered: Bool, grabEsc: Bool = true) {
        isHovered = hovered
        overlay.isHidden = !hovered
        if hovered, grabEsc, escToken == nil {
            escToken = HotKeyCenter.shared.registerToken(keyCode: kVK_Escape, modifiers: 0) { [weak self] in
                self?.actions.close()
            }.id
        } else if !hovered, let token = escToken {
            HotKeyCenter.shared.unregister(token)
            escToken = nil
        }
    }

    /// 閉じるときに Esc を必ず手放す（ホバー中に閉じると mouseExited が来ない）
    func releaseEsc() {
        setHovered(false)
    }

    // MARK: - ドラッグで持ち出す

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint else { return }
        let p = event.locationInWindow
        guard hypot(p.x - start.x, p.y - start.y) > 3 else { return }
        mouseDownPoint = nil
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(bounds, contents: image)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownPoint = nil
    }

    /// 持ち出しはコピーに限る（Finder で同じボリュームへ落とすと既定では移動になり、~/Downloads から消えるため）
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        Log.write("thumbnail.drag_ended operation=\(operation.rawValue)")
        if operation != [] { actions.draggedOut() }
    }
}

/// クロージャで押下を受けるボタン。非アクティブなパネルでも 1 回目のクリックで押せるようにする。
/// 薄いグレーの面に黒い中身。乗ると白く、押すと暗くなる
private class ActionButton: NSButton {
    private static let fill = NSColor(white: 0.9, alpha: 0.95)
    private static let hoverFill = NSColor(white: 1, alpha: 1)
    private static let pressedFill = NSColor(white: 0.75, alpha: 0.95)

    var onPress: (() -> Void)?

    init(size: NSSize, tip: String, action: @escaping () -> Void) {
        super.init(frame: NSRect(origin: .zero, size: size))
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = min(size.width, size.height) / 2
        layer?.backgroundColor = Self.fill.cgColor
        contentTintColor = .black
        toolTip = tip
        onPress = action
        target = self
        self.action = #selector(press)
        widthAnchor.constraint(equalToConstant: size.width).isActive = true
        heightAnchor.constraint(equalToConstant: size.height).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func press() { onPress?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { layer?.backgroundColor = Self.hoverFill.cgColor }
    override func mouseExited(with event: NSEvent) { layer?.backgroundColor = Self.fill.cgColor }

    /// super.mouseDown はボタンを離すまで戻らない
    override func mouseDown(with event: NSEvent) {
        layer?.backgroundColor = Self.pressedFill.cgColor
        super.mouseDown(with: event)
        let inside = bounds.contains(convert(window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil))
        layer?.backgroundColor = (inside ? Self.hoverFill : Self.fill).cgColor
    }
}

/// 四隅の丸いアイコンボタン
private final class CircleButton: ActionButton {
    static let diameter: CGFloat = 26

    init(_ symbol: String, tip: String, action: @escaping () -> Void) {
        super.init(size: NSSize(width: Self.diameter, height: Self.diameter), tip: tip, action: action)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .bold))
        imagePosition = .imageOnly
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// 中央の Copy / Save。文字幅に合わせた横長の角丸
private final class PillButton: ActionButton {
    private static let font = NSFont.systemFont(ofSize: 14, weight: .semibold)
    private static let height: CGFloat = 28
    private static let width: CGFloat = 70

    init(_ label: String, tip: String, action: @escaping () -> Void) {
        super.init(size: NSSize(width: Self.width, height: Self.height), tip: tip, action: action)
        setLabel(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    func setLabel(_ label: String) {
        attributedTitle = NSAttributedString(string: label, attributes: [
            .font: Self.font, .foregroundColor: NSColor.black,
        ])
    }
}
