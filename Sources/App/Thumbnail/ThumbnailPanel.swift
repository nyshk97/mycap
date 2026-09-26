import AppKit
import AVFoundation
import Carbon
import CoreImage

/// 録画のサムネイルに出す情報（長さ・大きさ・音声の有無）
struct VideoInfo {
    let duration: TimeInterval
    let bytes: Int64
    let hasAudio: Bool
}

/// 撮影後に画面の隅へ出るサムネイル 1 枚。アプリをアクティブにしない NSPanel で、全 Space・フルスクリーンの上にも出る
final class ThumbnailPanel: NSPanel {
    let url: URL
    let thumbnailView: ThumbnailView

    init(url: URL, image: NSImage, size: NSSize, video: VideoInfo?, actions: ThumbnailView.Actions) {
        self.url = url
        thumbnailView = ThumbnailView(frame: NSRect(origin: .zero, size: size), url: url, image: image, video: video, actions: actions)
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

/// サムネイルの中身。画像・ホバー時のボタン・ドラッグでの持ち出し。
/// 録画はホバー中にサムネイルの中で無音ループ再生し、下端に進捗バーを出す
final class ThumbnailView: NSView, NSDraggingSource {
    struct Actions {
        /// コピー・保存・OCR は済んだらサムネイルを閉じる（保存は失敗したら閉じない）。編集（録画はトリム）・ピン留め・プレビューは閉じない
        var copy: () -> Void
        /// ~/Downloads へ保存する
        var save: () -> Void
        var pin: () -> Void
        var ocr: () -> Void
        var edit: () -> Void
        /// 録画を大きく再生する（目のボタン / Space）
        var preview: () -> Void
        var close: () -> Void
        /// ドラッグで持ち出せたとき（ドロップ先が受け取ったとき）
        var draggedOut: () -> Void
    }

    private let url: URL
    private let image: NSImage
    private let actions: Actions
    /// 録画のときだけある。録画はピン・OCR を出さず、編集の代わりにトリム、ピンの代わりにプレビュー
    private let video: VideoInfo?
    private var isVideo: Bool { video != nil }
    private let overlay = NSView()
    private var infoPills: NSView?
    /// ホバー中の再生（最初に乗せたときに作る）
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var playerLayer: AVPlayerLayer?
    private var timeObserver: Any?
    private let progress = NSView()
    /// Space（プレビュー）はホバー中だけ取る。待ち受け中に取ると、前面のアプリで打った空白を奪うため
    private var spaceToken: UInt32?
    private var mouseDownPoint: NSPoint?
    /// ホバー中・待ち受け中だけ取っているキー（Esc と ⌘C / ⌘S / ⌘O / ⌘E / ⌘P）の登録 id
    private var keyTokens: [UInt32] = []
    private(set) var isHovered = false
    /// 撮った直後の待ち受け（マウスを乗せなくてもキーを受ける）。解くきっかけは `ThumbnailController` が見張る
    private(set) var isArmed = false
    /// マウスの出入り（`ThumbnailController` がキーの持ち主を 1 枚に保つため）
    var onHoverChange: ((Bool) -> Void)?
    var keyCount: Int { keyTokens.count }

    init(frame: NSRect, url: URL, image: NSImage, video: VideoInfo?, actions: Actions) {
        self.url = url
        self.image = image
        self.video = video
        self.actions = actions
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor(white: 0.12, alpha: 0.92).cgColor
        applyBorder()

        let imageView = NSImageView(frame: bounds)
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.autoresizingMask = [.width, .height]
        addSubview(imageView)

        // ホバー中は CleanShot X と同じく、画像をぼかして暗くした上にボタンを出す。
        // 録画はぼかさず薄く暗くするだけ（再生している中身が見えるように）
        overlay.frame = bounds
        overlay.autoresizingMask = [.width, .height]
        overlay.wantsLayer = true
        overlay.isHidden = true
        if !isVideo {
            let blurred = NSImageView(frame: bounds)
            blurred.image = Self.blurred(image, displayWidth: frame.width)
            blurred.imageScaling = .scaleProportionallyUpOrDown
            blurred.autoresizingMask = [.width, .height]
            overlay.addSubview(blurred)
        }
        let dim = NSView(frame: bounds)
        dim.wantsLayer = true
        if isVideo {
            // 録画は上下（ボタンのある所）だけ暗くして、真ん中の映像を見せる
            let gradient = CAGradientLayer()
            let edge = NSColor(white: 0, alpha: 0.35).cgColor, clear = NSColor(white: 0, alpha: 0.05).cgColor
            gradient.colors = [edge, clear, clear, edge]
            gradient.locations = [0, 0.4, 0.6, 1]
            gradient.frame = bounds
            gradient.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            dim.layer?.addSublayer(gradient)
        } else {
            dim.layer?.backgroundColor = NSColor(calibratedRed: 0.04, green: 0.05, blue: 0.06, alpha: 0.38).cgColor
        }
        dim.autoresizingMask = [.width, .height]
        overlay.addSubview(dim)
        addSubview(overlay)
        buildButtons()
        if let video { addVideoInfo(video) }
    }

    deinit {
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 四隅に丸ボタン（左上 閉じる・右上 ピン・左下 編集・右下 OCR）、中央に Copy / Save。
    /// 録画は 左上 閉じる・右上 プレビュー・左下 トリム・右下 コピー、中央に Save だけ
    private func buildButtons() {
        let inset: CGFloat = 8
        let d = CircleButton.diameter
        func corner(_ button: NSButton, left: Bool, top: Bool) {
            button.frame.origin = NSPoint(x: left ? inset : bounds.width - inset - d,
                                          y: top ? bounds.height - inset - d : inset)
            button.autoresizingMask = [left ? .maxXMargin : .minXMargin, top ? .minYMargin : .maxYMargin]
            overlay.addSubview(button)
        }
        corner(CircleButton("xmark", tip: "閉じる（Esc）") { [weak self] in self?.actions.close() }, left: true, top: true)
        if isVideo {
            corner(CircleButton("eye", tip: "プレビュー（Space）") { [weak self] in self?.actions.preview() }, left: false, top: true)
            corner(CircleButton("scissors", tip: "トリム（⌘E）") { [weak self] in self?.actions.edit() }, left: true, top: false)
            corner(CircleButton("doc.on.doc", tip: "コピー（⌘C）") { [weak self] in self?.actions.copy() }, left: false, top: false)
        } else {
            corner(CircleButton("pin.fill", tip: "ピン留め（⌘P）") { [weak self] in self?.actions.pin() }, left: false, top: true)
            corner(CircleButton("pencil", tip: "編集（矢印・四角・モザイク・文字）（⌘E）") { [weak self] in self?.actions.edit() }, left: true, top: false)
            corner(CircleButton("text.viewfinder", tip: "OCR（文字をコピー）（⌘O）") { [weak self] in self?.actions.ocr() }, left: false, top: false)
        }

        let save = PillButton("Save", tip: "保存（~/Downloads）（⌘S）") { [weak self] in self?.actions.save() }
        let pills = isVideo ? [save] : [PillButton("Copy", tip: "コピー（⌘C）") { [weak self] in self?.actions.copy() }, save]
        let column = NSStackView(views: pills)
        column.orientation = .vertical
        column.spacing = 7
        column.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(column)
        NSLayoutConstraint.activate([
            column.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            column.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
        ])
    }

    /// ホバー時の背景。表示の大きさで 8pt 相当のぼかしになるよう、画像のピクセル幅に合わせて半径を決める
    private static func blurred(_ image: NSImage, displayWidth: CGFloat) -> NSImage? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let input = CIImage(cgImage: cg)
        let radius = 8 * CGFloat(cg.width) / max(displayWidth, 1)
        guard let filter = CIFilter(name: "CIGaussianBlur") else { return nil }
        filter.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
        filter.setValue(radius, forKey: kCIInputRadiusKey)
        guard let output = filter.outputImage?.cropped(to: input.extent),
              let out = CIContext().createCGImage(output, from: input.extent) else { return nil }
        return NSImage(cgImage: out, size: image.size)
    }

    /// 左下の「🎥 0:12 · 2.4 MB」と、音声があれば 🔊。ホバー中は隠す（トリムのボタンと重なるため）
    private func addVideoInfo(_ video: VideoInfo) {
        func pill(symbol: String, text: String?) -> NSView {
            let icon = NSImageView()
            icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 9, weight: .bold))
            icon.contentTintColor = .white
            var views: [NSView] = [icon]
            if let text {
                let label = NSTextField(labelWithString: text)
                label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
                label.textColor = .white
                views.append(label)
            }
            let stack = NSStackView(views: views)
            stack.spacing = 4
            stack.edgeInsets = NSEdgeInsets(top: 0, left: 7, bottom: 0, right: 7)
            stack.wantsLayer = true
            stack.layer?.backgroundColor = NSColor(white: 0, alpha: 0.62).cgColor
            stack.layer?.cornerRadius = 10
            stack.heightAnchor.constraint(equalToConstant: 20).isActive = true
            return stack
        }
        var pills = [pill(symbol: "video.fill", text: VideoInfoText.label(seconds: video.duration, bytes: video.bytes))]
        if video.hasAudio { pills.append(pill(symbol: "speaker.wave.2.fill", text: nil)) }
        let row = NSStackView(views: pills)
        row.spacing = 4
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row, positioned: .below, relativeTo: overlay)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -7),
        ])
        infoPills = row

        progress.wantsLayer = true
        progress.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        progress.frame = NSRect(x: 0, y: 0, width: 0, height: 3)
        progress.isHidden = true
        addSubview(progress)
    }

    // MARK: - ホバー中の再生

    private func startPlayback() {
        guard isVideo else { return }
        if player == nil {
            let item = AVPlayerItem(url: url)
            let queue = AVQueuePlayer()
            queue.isMuted = true
            looper = AVPlayerLooper(player: queue, templateItem: item)
            let layer = AVPlayerLayer(player: queue)
            layer.videoGravity = .resizeAspect
            layer.frame = bounds
            layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            // 先頭のフレームの画像と overlay の間に挟む
            let host = NSView(frame: bounds)
            host.autoresizingMask = [.width, .height]
            host.wantsLayer = true
            host.layer?.addSublayer(layer)
            addSubview(host, positioned: .below, relativeTo: infoPills ?? overlay)
            let duration = max(video?.duration ?? 0, 0.01)
            timeObserver = queue.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
                guard let self else { return }
                let t = time.seconds.truncatingRemainder(dividingBy: duration)
                progress.frame.size.width = bounds.width * CGFloat(min(max(t / duration, 0), 1))
            }
            player = queue
            playerLayer = layer
        }
        playerLayer?.isHidden = false
        progress.isHidden = false
        player?.seek(to: .zero)
        player?.play()
    }

    private func stopPlayback() {
        guard let player else { return }
        player.pause()
        playerLayer?.isHidden = true
        progress.isHidden = true
        progress.frame.size.width = 0
    }

    /// 検証フックの `--dump-thumbs` 用。録画でなければ nil
    var videoState: String? {
        guard let video else { return nil }
        let label = VideoInfoText.label(seconds: video.duration, bytes: video.bytes).replacingOccurrences(of: " ", with: "_")
        let playing = (player?.rate ?? 0) > 0
        return "video=\(label) audio=\(video.hasAudio) info_shown=\(!(infoPills?.isHidden ?? true)) playing=\(playing) progress=\(Int(progress.frame.width)) space=\(spaceToken != nil)"
    }

    /// 検証フックの `--save-newest` 用
    func pressSave() { actions.save() }
    /// 検証フックの `--pin-newest` 用
    func pressPin() { actions.pin() }

    // MARK: - ホバー

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        if isArmed {
            // 待ち受け中の自分に乗せたときは、キーを残したままホバーに引き継ぐ
            setHovered(true)
            onHoverChange?(true)
        } else {
            // 先に controller へ知らせて、ほかのサムネイルの待ち受けのキーを手放させてから取る
            onHoverChange?(true)
            setHovered(true)
        }
    }

    override func mouseExited(with event: NSEvent) {
        setHovered(false)
        onHoverChange?(false)
    }

    /// ホバー中だけ Esc と ⌘C / ⌘S / ⌘O / ⌘E / ⌘P をホットキーとして取る（キー監視のアクセシビリティ許可を要らなくするため）。
    /// ホバーしていない間は登録しないので、前面のアプリの ⌘C 等はそのまま効く（待ち受け中を除く）。
    /// `grabKeys: false` は検証フックでボタンの見た目だけ撮るとき
    func setHovered(_ hovered: Bool, grabKeys: Bool = true) {
        let changed = isHovered != hovered
        isHovered = hovered
        overlay.isHidden = !hovered
        infoPills?.isHidden = hovered
        if changed { hovered ? startPlayback() : stopPlayback() }
        if isVideo {
            if hovered, grabKeys, spaceToken == nil {
                spaceToken = register(kVK_Space, 0, "space") { [weak self] in self?.actions.preview() }
            } else if !hovered, let token = spaceToken {
                HotKeyCenter.shared.unregister(token)
                spaceToken = nil
            }
        }
        if hovered, grabKeys, keyTokens.isEmpty {
            registerHoverKeys()
        } else if !hovered, !isArmed {
            unregisterKeys()
        }
    }

    /// 待ち受けに入る／解く。画像は隠さず枠だけ光らせる（撮った中身を確かめたいのはこの瞬間なので）。
    /// `grabKeys: false` は検証用の起動（`MYCAP_ARM_KEYS=0`）
    func setArmed(_ armed: Bool, grabKeys: Bool) {
        isArmed = armed
        applyBorder()
        if armed, grabKeys, keyTokens.isEmpty {
            registerHoverKeys()
        } else if !armed, !isHovered {
            unregisterKeys()
        }
    }

    private func applyBorder() {
        layer?.borderColor = (isArmed ? NSColor.controlAccentColor : NSColor(white: 1, alpha: 0.18)).cgColor
        layer?.borderWidth = isArmed ? 3 : 1
    }

    private func unregisterKeys() {
        keyTokens.forEach(HotKeyCenter.shared.unregister)
        keyTokens.removeAll()
    }

    private func register(_ code: Int, _ mods: Int, _ name: String, _ run: @escaping () -> Void) -> UInt32? {
        let result = HotKeyCenter.shared.registerToken(keyCode: code, modifiers: mods) {
            Log.write("thumbnail.key key=\(name)")
            run()
        }
        if result.id == nil { Log.write("thumbnail.key_register_failed key=\(name) status=\(result.status)") }
        return result.id
    }

    private func registerHoverKeys() {
        var keys: [(code: Int, mods: Int, name: String, run: () -> Void)] = [
            (kVK_Escape, 0, "esc", { [weak self] in self?.actions.close() }),
            (kVK_ANSI_S, cmdKey, "cmd_s", { [weak self] in self?.actions.save() }),
            (kVK_ANSI_C, cmdKey, "cmd_c", { [weak self] in self?.actions.copy() }),
            (kVK_ANSI_E, cmdKey, "cmd_e", { [weak self] in self?.actions.edit() }),
        ]
        if !isVideo {
            keys += [
                (kVK_ANSI_O, cmdKey, "cmd_o", { [weak self] in self?.actions.ocr() }),
                (kVK_ANSI_P, cmdKey, "cmd_p", { [weak self] in self?.actions.pin() }),
            ]
        }
        for key in keys {
            if let id = register(key.code, key.mods, key.name, key.run) { keyTokens.append(id) }
        }
    }

    /// 閉じるときにキーを必ず手放す（ホバー中に閉じると mouseExited が来ない）
    func releaseKeys() {
        isArmed = false
        applyBorder()
        setHovered(false)
    }

    // MARK: - ドラッグで持ち出す

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        // 録画はダブルクリックでトリム（CleanShot X と同じ）
        if isVideo, event.clickCount == 2 {
            mouseDownPoint = nil
            actions.edit()
            return
        }
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
/// 半透明の黒に白い中身と 0.5pt の白い縁（ダークガラス）。どんな色のスクショの上でも沈まない。乗ると白く明るく、押すと暗くなる
class ActionButton: NSButton {
    private static let fill = NSColor(calibratedRed: 0.12, green: 0.125, blue: 0.15, alpha: 0.6)
    private static let hoverFill = NSColor(white: 1, alpha: 0.3)
    private static let pressedFill = NSColor(white: 0, alpha: 0.7)

    var onPress: (() -> Void)?

    init(size: NSSize, tip: String, action: @escaping () -> Void) {
        super.init(frame: NSRect(origin: .zero, size: size))
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = min(size.width, size.height) / 2
        layer?.backgroundColor = Self.fill.cgColor
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor(white: 1, alpha: 0.3).cgColor
        shadow = {
            let s = NSShadow()
            s.shadowColor = NSColor(white: 0, alpha: 0.3)
            s.shadowOffset = NSSize(width: 0, height: -1)
            s.shadowBlurRadius = 3
            return s
        }()
        contentTintColor = .white
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

/// 四隅の丸いアイコンボタン（ピンの閉じるボタンにも使う）
final class CircleButton: ActionButton {
    static let diameter: CGFloat = 26

    init(_ symbol: String, tip: String, action: @escaping () -> Void) {
        super.init(size: NSSize(width: Self.diameter, height: Self.diameter), tip: tip, action: action)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        imagePosition = .imageOnly
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// 中央の Copy / Save。文字幅なりの横長の角丸（最小幅はそろえる）
private final class PillButton: ActionButton {
    private static let font = NSFont.systemFont(ofSize: 13, weight: .semibold)
    private static let height: CGFloat = 28
    private static let minWidth: CGFloat = 64

    init(_ label: String, tip: String, action: @escaping () -> Void) {
        let textWidth = (label as NSString).size(withAttributes: [.font: Self.font]).width
        super.init(size: NSSize(width: max(Self.minWidth, ceil(textWidth) + 32), height: Self.height), tip: tip, action: action)
        attributedTitle = NSAttributedString(string: label, attributes: [
            .font: Self.font, .foregroundColor: NSColor.white,
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}
