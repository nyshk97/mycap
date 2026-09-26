import AppKit

/// オールインワンの暗幕。ドラッグで範囲を作り、内側のドラッグで移動、四隅と四辺のハンドルで大きさを変える。範囲の外のドラッグは選び直し。
/// 座標はこのビューのローカル（左下原点のポイント）。範囲の計算は `AIOLayout`
final class AIOSelectionView: NSView {
    private enum Drag {
        case creating(start: CGPoint, previous: CGRect?)
        case moving(last: CGPoint)
        case resizing(AIOLayout.Handle)
    }

    private(set) var selection: CGRect?
    private var drag: Drag?
    /// 範囲が変わった（`dragging` は新しく作っている途中。ツールバーと W × H はこの間も追従する）
    var onChange: ((CGRect?, _ dragging: Bool) -> Void)?
    var onCancel: (() -> Void)?
    var onEnter: (() -> Void)?

    private static let handleSize: CGFloat = 8
    private static let handleHit: CGFloat = 14

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func setSelection(_ rect: CGRect?) {
        selection = rect
        needsDisplay = true
        onChange?(rect, false)
    }

    // MARK: - 描画

    override func draw(_ dirtyRect: NSRect) {
        let dim = NSBezierPath(rect: bounds)
        if let s = selection {
            dim.append(NSBezierPath(rect: s))
            dim.windingRule = .evenOdd
        }
        NSColor(white: 0, alpha: 0.42).setFill()
        dim.fill()

        guard let s = selection else {
            drawHint()
            return
        }
        NSColor.white.withAlphaComponent(0.9).setStroke()
        let border = NSBezierPath(rect: s.insetBy(dx: -0.5, dy: -0.5))
        border.lineWidth = 1
        border.stroke()
        if case .creating = drag { return }
        for h in AIOLayout.Handle.allCases {
            let c = Self.point(of: h, in: s)
            let r = NSRect(x: c.x - Self.handleSize / 2, y: c.y - Self.handleSize / 2, width: Self.handleSize, height: Self.handleSize)
            let path = NSBezierPath(roundedRect: r, xRadius: 2, yRadius: 2)
            NSColor.white.setFill()
            path.fill()
            NSColor(white: 0, alpha: 0.35).setStroke()
            path.lineWidth = 0.5
            path.stroke()
        }
    }

    private func drawHint() {
        let text = "ドラッグで範囲を選ぶ　　Esc でキャンセル" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.85),
        ]
        let size = text.size(withAttributes: attrs)
        let box = NSRect(x: bounds.midX - size.width / 2 - 16, y: bounds.midY - size.height / 2 - 10,
                         width: size.width + 32, height: size.height + 20)
        NSColor(white: 0.1, alpha: 0.75).setFill()
        NSBezierPath(roundedRect: box, xRadius: 10, yRadius: 10).fill()
        text.draw(at: NSPoint(x: box.minX + 16, y: box.minY + 10), withAttributes: attrs)
    }

    private static func point(of h: AIOLayout.Handle, in s: CGRect) -> CGPoint {
        switch h {
        case .topLeft: CGPoint(x: s.minX, y: s.maxY)
        case .top: CGPoint(x: s.midX, y: s.maxY)
        case .topRight: CGPoint(x: s.maxX, y: s.maxY)
        case .right: CGPoint(x: s.maxX, y: s.midY)
        case .bottomRight: CGPoint(x: s.maxX, y: s.minY)
        case .bottom: CGPoint(x: s.midX, y: s.minY)
        case .bottomLeft: CGPoint(x: s.minX, y: s.minY)
        case .left: CGPoint(x: s.minX, y: s.midY)
        }
    }

    private func handle(at p: CGPoint) -> AIOLayout.Handle? {
        guard let s = selection else { return nil }
        return AIOLayout.Handle.allCases.first { h in
            let c = Self.point(of: h, in: s)
            return abs(c.x - p.x) <= Self.handleHit / 2 && abs(c.y - p.y) <= Self.handleHit / 2
        }
    }

    // MARK: - マウス

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        if let h = handle(at: p) {
            drag = .resizing(h)
        } else if let s = selection, s.contains(p) {
            drag = .moving(last: p)
        } else {
            drag = .creating(start: p, previous: selection)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        switch drag {
        case let .creating(start, _):
            // 16pt 未満のあいだは今の範囲をそのまま見せる
            if let r = AIOLayout.rect(from: start, to: p, in: bounds) { update(r, dragging: true) }
        case let .moving(last):
            guard let s = selection else { return }
            let m = AIOLayout.moved(s, by: CGSize(width: p.x - last.x, height: p.y - last.y), in: bounds)
            update(m, dragging: false)
            // 端で止まった分を持ち越さないよう、実際に動いた量だけ基準点を進める
            drag = .moving(last: CGPoint(x: last.x + (m.minX - s.minX), y: last.y + (m.minY - s.minY)))
        case let .resizing(h):
            guard let s = selection else { return }
            update(AIOLayout.resized(s, handle: h, to: p, in: bounds), dragging: false)
        case nil:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if case let .creating(start, previous) = drag {
            drag = nil
            // クリックだけ・16pt 未満のドラッグは無視して、前の範囲に戻す
            let made = AIOLayout.rect(from: start, to: p, in: bounds)
            if let made { Log.write("aio.selected rect=\(NSStringFromRect(made))") }
            update(made ?? previous, dragging: false)
        } else {
            drag = nil
            needsDisplay = true
        }
        updateCursor(at: p)
    }

    private func update(_ r: CGRect?, dragging: Bool) {
        selection = r
        needsDisplay = true
        onChange?(r, dragging)
    }

    // MARK: - カーソル

    /// mycap は前面にならないので cursor rect が効かないことがある。マウスの移動のたびに自分で切り替える
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate], owner: self))
    }

    override func mouseMoved(with event: NSEvent) { updateCursor(at: convert(event.locationInWindow, from: nil)) }
    override func cursorUpdate(with event: NSEvent) { updateCursor(at: convert(event.locationInWindow, from: nil)) }

    func updateCursor(at p: CGPoint) {
        if let h = handle(at: p) {
            Self.cursor(for: h).set()
        } else if let s = selection, s.contains(p) {
            NSCursor.openHand.set()
        } else {
            NSCursor.crosshair.set()
        }
    }

    private static func cursor(for h: AIOLayout.Handle) -> NSCursor {
        switch h {
        case .topLeft: .frameResize(position: .topLeft, directions: .all)
        case .top: .frameResize(position: .top, directions: .all)
        case .topRight: .frameResize(position: .topRight, directions: .all)
        case .right: .frameResize(position: .right, directions: .all)
        case .bottomRight: .frameResize(position: .bottomRight, directions: .all)
        case .bottom: .frameResize(position: .bottom, directions: .all)
        case .bottomLeft: .frameResize(position: .bottomLeft, directions: .all)
        case .left: .frameResize(position: .left, directions: .all)
        }
    }

    // MARK: - キー

    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case 53: onCancel?() // Esc
        case 36, 76: if selection != nil { onEnter?() } // Return / Enter
        default: super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) { onCancel?() }
}
