import AppKit
import Carbon

/// 撮影後に画面の隅へ出るサムネイル 1 枚。アプリをアクティブにしない NSPanel で、全 Space・フルスクリーンの上にも出る
final class ThumbnailPanel: NSPanel {
    let url: URL
    let thumbnailView: ThumbnailView

    init(url: URL, image: NSImage, size: NSSize, actions: ThumbnailView.Actions) {
        self.url = url
        thumbnailView = ThumbnailView(frame: NSRect(origin: .zero, size: size), url: url, image: image, actions: actions)
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
        var revealInFinder: () -> Void
        var pin: () -> Void
        var ocr: () -> Void
        var style: () -> Void
        var trash: () -> Void
        var close: () -> Void
        /// ドラッグで持ち出せたとき（ドロップ先が受け取ったとき）
        var draggedOut: () -> Void
    }

    private let url: URL
    private let image: NSImage
    private let actions: Actions
    private let overlay = NSView()
    private var mouseDownPoint: NSPoint?
    private var escToken: UInt32?
    private(set) var isHovered = false

    init(frame: NSRect, url: URL, image: NSImage, actions: Actions) {
        self.url = url
        self.image = image
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

        overlay.frame = bounds
        overlay.autoresizingMask = [.width, .height]
        overlay.wantsLayer = true
        overlay.layer?.backgroundColor = NSColor(white: 0, alpha: 0.45).cgColor
        overlay.isHidden = true
        addSubview(overlay)
        buildButtons()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func buildButtons() {
        let close = Self.button("xmark.circle.fill", tip: "閉じる（Esc）") { [weak self] in self?.actions.close() }
        let trash = Self.button("trash", tip: "削除（ゴミ箱へ）") { [weak self] in self?.actions.trash() }
        close.frame.origin = NSPoint(x: 6, y: bounds.height - 30)
        close.autoresizingMask = [.maxXMargin, .minYMargin]
        trash.frame.origin = NSPoint(x: bounds.width - 30, y: bounds.height - 30)
        trash.autoresizingMask = [.minXMargin, .minYMargin]
        overlay.addSubview(close)
        overlay.addSubview(trash)

        let row = NSStackView(views: [
            Self.button("doc.on.doc", tip: "コピー") { [weak self] in self?.actions.copy() },
            Self.button("pin", tip: "ピン留め") { [weak self] in self?.actions.pin() },
            Self.button("text.viewfinder", tip: "OCR（文字をコピー）") { [weak self] in self?.actions.ocr() },
            Self.button("wand.and.stars", tip: "整形（背景と余白）") { [weak self] in self?.actions.style() },
            Self.button("folder", tip: "Finder で表示") { [weak self] in self?.actions.revealInFinder() },
        ])
        row.orientation = .horizontal
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(row)
        NSLayoutConstraint.activate([
            row.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            row.bottomAnchor.constraint(equalTo: overlay.bottomAnchor, constant: -8),
        ])
    }

    private static func button(_ symbol: String, tip: String, action: @escaping () -> Void) -> NSButton {
        let b = ActionButton(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .semibold))
        b.contentTintColor = .white
        b.isBordered = false
        b.toolTip = tip
        b.onPress = action
        b.target = b
        b.action = #selector(ActionButton.press)
        b.widthAnchor.constraint(equalToConstant: 24).isActive = true
        b.heightAnchor.constraint(equalToConstant: 24).isActive = true
        return b
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

/// クロージャで押下を受けるボタン。非アクティブなパネルでも 1 回目のクリックで押せるようにする
private final class ActionButton: NSButton {
    var onPress: (() -> Void)?
    @objc func press() { onPress?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
