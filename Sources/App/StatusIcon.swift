import AppKit

/// メニューバーのアイコン。アプリアイコンと同じ「範囲選択の四隅のかぎ括弧＋中央の点」のテンプレート画像
/// （明暗はシステムが合わせる）
enum StatusIcon {
    static func make() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let r = NSRect(x: 2, y: 3, width: 14, height: 12)
            let arm: CGFloat = 4
            let path = NSBezierPath()
            for (x, y, dx, dy) in [(r.minX, r.minY, arm, arm), (r.maxX, r.minY, -arm, arm),
                                   (r.minX, r.maxY, arm, -arm), (r.maxX, r.maxY, -arm, -arm)] {
                path.move(to: NSPoint(x: x, y: y + dy))
                path.line(to: NSPoint(x: x, y: y))
                path.line(to: NSPoint(x: x + dx, y: y))
            }
            path.lineWidth = 1.6
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            NSColor.black.setStroke()
            path.stroke()
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: 9 - 1.8, y: 9 - 1.8, width: 3.6, height: 3.6)).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "mycap"
        return image
    }
}
