import AppKit

/// 編集の画像と注釈を描き、マウスで描く・選ぶ・動かす・大きさを変えるを受ける。
/// 画面の座標（ポイント・左上原点）と画像の座標（ピクセル・左上原点）を `viewScale` で行き来する
final class EditorCanvas: NSView, NSTextViewDelegate {
    private let model: EditorModel
    /// ⇧ なしの Esc（何も選んでいないとき）で閉じる
    var onEscape: (() -> Void)?

    private enum Drag {
        case none
        case create(UUID)
        case move(UUID, from: CGPoint, original: Annotation)
        case resize(UUID, AnnotationGeometry.Handle)
    }

    private var drag = Drag.none
    /// ドラッグを始める直前の要素（離したときに 1 回分の取り消しとして積む）
    private var dragBefore: [Annotation] = []
    private var mosaicCache: [String: CGImage] = [:]

    /// 入力中の文字
    private var textView: AnnotationTextView?
    private var editingID: UUID?
    private var textBefore: [Annotation] = []

    private static let margin: CGFloat = 16
    private static let handleSize: CGFloat = 8

    init(model: EditorModel) {
        self.model = model
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var isEditingText: Bool { textView != nil }

    // MARK: - 座標

    private var imagePixels: CGSize { CGSize(width: model.image.width, height: model.image.height) }

    /// 画像を置く場所（原寸のポイントで収まれば原寸、収まらなければ縮めて中央に）
    var imageRect: CGRect {
        let pt = CGSize(width: imagePixels.width / model.scale, height: imagePixels.height / model.scale)
        let avail = bounds.insetBy(dx: Self.margin, dy: Self.margin)
        let s = max(0.01, min(avail.width / pt.width, avail.height / pt.height, 1))
        let size = CGSize(width: pt.width * s, height: pt.height * s)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    }

    /// 画面のポイント / 画像のピクセル
    var viewScale: CGFloat { imageRect.width / imagePixels.width }

    private func toImage(_ p: NSPoint) -> CGPoint {
        let r = imageRect, s = viewScale
        return CGPoint(x: (p.x - r.minX) / s, y: (p.y - r.minY) / s)
    }

    private func toView(_ p: CGPoint) -> NSPoint {
        let r = imageRect, s = viewScale
        return NSPoint(x: r.minX + p.x * s, y: r.minY + p.y * s)
    }

    private func toView(_ rect: CGRect) -> NSRect {
        let o = toView(rect.origin)
        return NSRect(x: o.x, y: o.y, width: rect.width * viewScale, height: rect.height * viewScale)
    }

    /// 当たり判定の遊び（画面で 6pt）
    private var tolerance: Double { 6 / viewScale }

    // MARK: - 描画

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        NSColor(white: 0.14, alpha: 1).setFill()
        bounds.fill()

        let r = imageRect
        ctx.saveGState()
        ctx.translateBy(x: r.minX, y: r.minY)
        ctx.scaleBy(x: viewScale, y: viewScale)
        let full = CGRect(origin: .zero, size: imagePixels)
        ctx.clip(to: full)
        ctx.interpolationQuality = .high
        AnnotationRenderer.drawImage(model.image, in: full, ctx: ctx)
        for a in model.annotations where a.id != editingID {
            AnnotationRenderer.draw(a, in: ctx, mosaic: a.kind == .mosaic ? mosaic(for: a) : nil)
        }
        ctx.restoreGState()

        if let sel = model.selected, sel.id != editingID { drawSelection(sel) }
    }

    private func mosaic(for a: Annotation) -> CGImage? {
        let key = "\(a.rect.integral)|\(a.size)"
        if let hit = mosaicCache[key] { return hit }
        if mosaicCache.count > 64 { mosaicCache.removeAll() }
        let img = AnnotationRenderer.pixelated(model.image, rect: a.rect, block: a.size)
        mosaicCache[key] = img
        return img
    }

    private func drawSelection(_ a: Annotation) {
        let box = toView(AnnotationGeometry.bounds(a)).insetBy(dx: -4, dy: -4)
        if a.kind == .text || a.kind == .arrow {
            let path = NSBezierPath(rect: box)
            path.lineWidth = 1
            path.setLineDash([4, 3], count: 2, phase: 0)
            NSColor.controlAccentColor.setStroke()
            path.stroke()
        }
        for (_, p) in AnnotationGeometry.handles(a) {
            let c = toView(p), s = Self.handleSize
            let knob = NSBezierPath(ovalIn: NSRect(x: c.x - s / 2, y: c.y - s / 2, width: s, height: s))
            NSColor.white.setFill()
            knob.fill()
            NSColor.controlAccentColor.setStroke()
            knob.lineWidth = 1.5
            knob.stroke()
        }
    }

    /// 要素が変わったとき（モデルから呼ぶ）
    func modelChanged() {
        needsDisplay = true
        refreshTextView()
    }

    override func resize(withOldSuperviewSize oldSize: NSSize) {
        super.resize(withOldSuperviewSize: oldSize)
        refreshTextView()
    }

    // MARK: - マウス

    override func mouseDown(with event: NSEvent) {
        if isEditingText { endTextEditing() }
        window?.makeFirstResponder(self)
        let p = toImage(convert(event.locationInWindow, from: nil))
        dragBefore = model.annotations
        drag = .none

        if let sel = model.selected, let h = AnnotationGeometry.handle(of: sel, at: p, tolerance: tolerance) {
            drag = .resize(sel.id, h)
            return
        }
        if let i = AnnotationGeometry.hit(model.annotations, at: p, tolerance: tolerance) {
            let a = model.annotations[i]
            model.select(a.id)
            if event.clickCount == 2, a.kind == .text {
                beginTextEditing(a.id, before: dragBefore)
                return
            }
            drag = .move(a.id, from: p, original: a)
            return
        }
        model.select(nil)
        guard CGRect(origin: .zero, size: imagePixels).contains(p) else { return }
        let a = model.newAnnotation(at: p)
        model.annotations.append(a)
        if a.kind == .text {
            model.select(a.id)
            beginTextEditing(a.id, before: dragBefore)
        } else {
            drag = .create(a.id)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = toImage(convert(event.locationInWindow, from: nil))
        let shift = event.modifierFlags.contains(.shift)
        switch drag {
        case .none:
            return
        case .create(let id):
            model.update(id) { $0.end = shift ? AnnotationGeometry.constrained($0.kind, from: $0.start, to: p) : p }
        case .move(let id, let from, let original):
            let moved = AnnotationGeometry.moved(original, by: CGSize(width: p.x - from.x, height: p.y - from.y))
            model.update(id) { $0 = moved }
        case .resize(let id, let handle):
            model.update(id) { $0 = AnnotationGeometry.resized($0, handle: handle, to: p) }
        }
    }

    override func mouseUp(with event: NSEvent) {
        if case .create(let id) = drag {
            if let a = model.annotations.first(where: { $0.id == id }), AnnotationGeometry.isMeaningful(a) {
                model.select(id)
            } else {
                model.remove(id)
            }
        }
        if case .none = drag { return }
        drag = .none
        model.commit(before: dragBefore)
    }

    override func resetCursorRects() {
        addCursorRect(imageRect, cursor: .crosshair)
    }

    // MARK: - キー

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .control, .option])
        switch Int(event.keyCode) {
        case 51, 117: // Delete / 前方削除
            model.deleteSelected()
            return
        case 53: // Esc
            if model.selectedID != nil { model.select(nil) } else { onEscape?() }
            return
        default:
            break
        }
        guard mods.isEmpty, let c = event.charactersIgnoringModifiers?.lowercased() else {
            super.keyDown(with: event)
            return
        }
        switch c {
        case "a": model.tool = .arrow
        case "r": model.tool = .rect
        case "p": model.tool = .mosaic
        case "t": model.tool = .text
        default: super.keyDown(with: event)
        }
        if model.selected.map({ $0.kind != model.tool }) == true { model.select(nil) }
    }

    // MARK: - 文字の入力

    private func beginTextEditing(_ id: UUID, before: [Annotation]) {
        guard let a = model.annotations.first(where: { $0.id == id }) else { return }
        textBefore = before
        editingID = id
        let tv = AnnotationTextView(frame: .zero)
        tv.isRichText = false
        tv.drawsBackground = false
        tv.allowsUndo = true
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isHorizontallyResizable = true
        tv.isVerticallyResizable = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.string = a.text
        tv.delegate = self
        tv.onCancel = { [weak self] in self?.endTextEditing() }
        textView = tv
        addSubview(tv)
        refreshTextView()
        window?.makeFirstResponder(tv)
        tv.setSelectedRange(NSRange(location: (a.text as NSString).length, length: 0))
        needsDisplay = true
    }

    /// 入力欄の見た目と位置を要素に合わせる（色・大きさ・フォントをツールバーで変えたとき、ウィンドウの大きさが変わったときも）
    private func refreshTextView() {
        guard let tv = textView, let id = editingID, let a = model.annotations.first(where: { $0.id == id }) else { return }
        let font = NSFont(name: a.font.rawValue, size: a.size * viewScale) ?? .systemFont(ofSize: a.size * viewScale)
        if tv.font != font { tv.font = font }
        let color = NSColor(cgColor: a.color.cgColor) ?? .red
        if tv.textColor != color { tv.textColor = color }
        tv.insertionPointColor = color
        let size = AnnotationRenderer.textSize(a)
        let o = toView(a.start)
        // 入力中はカーソルの分だけ広く取る
        tv.frame = NSRect(x: o.x, y: o.y, width: size.width * viewScale + font.pointSize, height: size.height * viewScale)
    }

    func textDidChange(_ notification: Notification) {
        guard let tv = textView, let id = editingID else { return }
        model.update(id) { $0.text = tv.string }
    }

    /// 入力を確定する（Esc・外をクリック・保存）。空なら要素ごと捨てる
    func endTextEditing() {
        guard let tv = textView, let id = editingID else { return }
        if tv.hasMarkedText() { tv.unmarkText() }
        model.update(id) { $0.text = tv.string }
        tv.removeFromSuperview()
        textView = nil
        editingID = nil
        if let a = model.annotations.first(where: { $0.id == id }), !AnnotationGeometry.isMeaningful(a) {
            model.remove(id)
        }
        model.commit(before: textBefore)
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    /// 入力中の ⌘Z は文字の取り消しにする
    var textUndoManager: UndoManager? { textView?.undoManager }
}

/// 注釈の文字の入力欄。日本語の変換中でなければ Esc で確定する
final class AnnotationTextView: NSTextView {
    var onCancel: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        if hasMarkedText() {
            super.cancelOperation(sender)
        } else {
            onCancel?()
        }
    }
}
