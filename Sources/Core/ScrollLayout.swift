import CoreGraphics

/// スクロールキャプチャ中のライブプレビューの置き場所（グローバル座標・左下原点）
enum ScrollLayout {
    enum Placement: String { case right, left, inside }

    /// 範囲の右の外 → 左の外 → 範囲の内側の右端、の順に置けるところへ。高さは範囲に揃え（`maxHeight` まで・上端を揃える）、
    /// バー（`bar`）と重なるなら、重ならないところまで縮める
    static func previewFrame(selection s: CGRect, bar: CGRect, bounds: CGRect, width w: CGFloat = 160,
                             maxHeight: CGFloat = 640, gap: CGFloat = 8, margin: CGFloat = 8) -> (frame: CGRect, placement: Placement) {
        let placement: Placement
        let x: CGFloat
        if s.maxX + gap + w <= bounds.maxX - margin {
            (placement, x) = (.right, s.maxX + gap)
        } else if s.minX - gap - w >= bounds.minX + margin {
            (placement, x) = (.left, s.minX - gap - w)
        } else {
            (placement, x) = (.inside, max(s.maxX - gap - w, bounds.minX + margin))
        }
        let top = min(s.maxY, bounds.maxY - margin)
        let bottom = max(top - min(s.height, maxHeight), bounds.minY + margin)
        var f = CGRect(x: x, y: bottom, width: w, height: top - bottom)
        if f.intersects(bar.insetBy(dx: -gap / 2, dy: -gap / 2)) {
            if bar.midY < f.midY {
                f = CGRect(x: f.minX, y: bar.maxY + gap, width: w, height: max(0, f.maxY - bar.maxY - gap))
            } else {
                f = CGRect(x: f.minX, y: f.minY, width: w, height: max(0, bar.minY - gap - f.minY))
            }
        }
        return (CGRect(x: f.minX.rounded(), y: f.minY.rounded(), width: w, height: f.height.rounded()), placement)
    }
}
