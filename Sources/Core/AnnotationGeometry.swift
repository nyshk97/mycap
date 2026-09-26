import CoreGraphics
import Foundation

/// 編集画面の当たり判定・ハンドル・移動とリサイズ（純粋関数）。座標はすべて画像のピクセル
enum AnnotationGeometry {
    /// リサイズのつまみ。矢印は両端、四角・モザイクは 8 点、文字は無い（大きさは文字の大きさで変える）
    enum Handle: String, CaseIterable {
        case start, end
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    }

    /// 選択枠に使う外接矩形
    static func bounds(_ a: Annotation) -> CGRect {
        switch a.kind {
        case .rect, .mosaic:
            return a.rect
        case .arrow:
            let pts = AnnotationRenderer.arrowPoints(from: a.start, to: a.end, width: a.size)
            let xs = pts.map(\.x), ys = pts.map(\.y)
            return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        case .text:
            return CGRect(origin: a.start, size: AnnotationRenderer.textSize(a))
        }
    }

    /// `point` に当たる一番上（最後に描いた）の要素の添字。四角は枠の線の近くだけ（中は下の要素や新しい描画に譲る）
    static func hit(_ annotations: [Annotation], at point: CGPoint, tolerance: Double) -> Int? {
        annotations.indices.reversed().first { contains(annotations[$0], point, tolerance: tolerance) }
    }

    static func contains(_ a: Annotation, _ p: CGPoint, tolerance t: Double) -> Bool {
        switch a.kind {
        case .arrow:
            return distance(p, segment: a.start, a.end) <= t + a.size * 1.8
        case .rect:
            let r = a.rect, pad = t + a.size / 2
            let outer = r.insetBy(dx: -pad, dy: -pad)
            let inner = r.insetBy(dx: pad, dy: pad)
            return outer.contains(p) && !(inner.width > 0 && inner.height > 0 && inner.contains(p))
        case .mosaic:
            return a.rect.insetBy(dx: -t, dy: -t).contains(p)
        case .text:
            return bounds(a).insetBy(dx: -t, dy: -t).contains(p)
        }
    }

    static func distance(_ p: CGPoint, segment a: CGPoint, _ b: CGPoint) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        guard len2 > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let u = min(max(((p.x - a.x) * dx + (p.y - a.y) * dy) / len2, 0), 1)
        return hypot(p.x - (a.x + u * dx), p.y - (a.y + u * dy))
    }

    static func handles(_ a: Annotation) -> [(Handle, CGPoint)] {
        switch a.kind {
        case .arrow:
            return [(.start, a.start), (.end, a.end)]
        case .rect, .mosaic:
            let r = a.rect
            return [
                (.topLeft, CGPoint(x: r.minX, y: r.minY)), (.top, CGPoint(x: r.midX, y: r.minY)),
                (.topRight, CGPoint(x: r.maxX, y: r.minY)), (.right, CGPoint(x: r.maxX, y: r.midY)),
                (.bottomRight, CGPoint(x: r.maxX, y: r.maxY)), (.bottom, CGPoint(x: r.midX, y: r.maxY)),
                (.bottomLeft, CGPoint(x: r.minX, y: r.maxY)), (.left, CGPoint(x: r.minX, y: r.midY)),
            ]
        case .text:
            return []
        }
    }

    static func handle(of a: Annotation, at p: CGPoint, tolerance t: Double) -> Handle? {
        handles(a).first { hypot($0.1.x - p.x, $0.1.y - p.y) <= t }?.0
    }

    static func moved(_ a: Annotation, by d: CGSize) -> Annotation {
        var b = a
        b.start = CGPoint(x: a.start.x + d.width, y: a.start.y + d.height)
        b.end = CGPoint(x: a.end.x + d.width, y: a.end.y + d.height)
        return b
    }

    /// つまみを `p` へ動かした結果。四角・モザイクは正規化した矩形の辺を動かす（反対側を越えたら裏返る）
    static func resized(_ a: Annotation, handle: Handle, to p: CGPoint) -> Annotation {
        var b = a
        switch handle {
        case .start: b.start = p
        case .end: b.end = p
        default:
            let r = a.rect
            var minX = r.minX, minY = r.minY, maxX = r.maxX, maxY = r.maxY
            switch handle {
            case .topLeft: minX = p.x; minY = p.y
            case .top: minY = p.y
            case .topRight: maxX = p.x; minY = p.y
            case .right: maxX = p.x
            case .bottomRight: maxX = p.x; maxY = p.y
            case .bottom: maxY = p.y
            case .bottomLeft: minX = p.x; maxY = p.y
            case .left: minX = p.x
            case .start, .end: break
            }
            b.start = CGPoint(x: minX, y: minY)
            b.end = CGPoint(x: maxX, y: maxY)
        }
        return b
    }

    /// ⇧ を押しながら描いたときの終点。四角・モザイクは正方形、矢印は 45° 刻み
    static func constrained(_ kind: Annotation.Kind, from s: CGPoint, to e: CGPoint) -> CGPoint {
        let dx = e.x - s.x, dy = e.y - s.y
        switch kind {
        case .rect, .mosaic:
            let side = max(abs(dx), abs(dy))
            return CGPoint(x: s.x + (dx < 0 ? -side : side), y: s.y + (dy < 0 ? -side : side))
        case .arrow:
            let length = hypot(dx, dy)
            let step = Double.pi / 4
            let angle = (atan2(dy, dx) / step).rounded() * step
            return CGPoint(x: s.x + cos(angle) * length, y: s.y + sin(angle) * length)
        case .text:
            return e
        }
    }

    /// 描き終えた要素を残すか（クリックだけで大きさの無いものは捨てる）
    static func isMeaningful(_ a: Annotation) -> Bool {
        switch a.kind {
        case .arrow: return hypot(a.end.x - a.start.x, a.end.y - a.start.y) >= 4
        case .rect, .mosaic: return a.rect.width >= 3 && a.rect.height >= 3
        case .text: return !a.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}

/// 取り消し・やり直し。変更の直前の要素の配列を丸ごと積む（要素は数十個までなので単純さを優先）
struct AnnotationHistory {
    private(set) var undoStack: [[Annotation]] = []
    private(set) var redoStack: [[Annotation]] = []

    /// 変更の直前に呼ぶ
    mutating func record(_ before: [Annotation]) {
        undoStack.append(before)
        redoStack.removeAll()
    }

    /// 取り消した後の配列。取り消せなければ nil
    mutating func undo(_ current: [Annotation]) -> [Annotation]? {
        guard let prev = undoStack.popLast() else { return nil }
        redoStack.append(current)
        return prev
    }

    mutating func redo(_ current: [Annotation]) -> [Annotation]? {
        guard let next = redoStack.popLast() else { return nil }
        undoStack.append(current)
        return next
    }
}
