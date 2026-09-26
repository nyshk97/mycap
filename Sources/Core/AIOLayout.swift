import CoreGraphics

/// オールインワン（⌘⇧5）の範囲とツールバーの位置（純粋関数）。
/// 座標は暗幕の中のローカル（左下原点のポイント。`bounds` はディスプレイの大きさの矩形）で扱い、
/// ScreenCaptureKit・`LastRegion` に渡すときだけ `topLeft` で左上原点にする。結果はどれも整数ポイントに丸める
enum AIOLayout {
    /// 範囲の最小の幅・高さ（ポイント）。これ未満のドラッグは範囲にしない
    static let minSize: CGFloat = 16

    enum Handle: CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    }

    /// ドラッグの 2 点から範囲を作る。はみ出た分はディスプレイで切る。小さすぎれば nil（クリックだけ等）
    static func rect(from a: CGPoint, to b: CGPoint, in bounds: CGRect) -> CGRect? {
        let p = clamp(a, to: bounds), q = clamp(b, to: bounds)
        let r = rounded(CGRect(x: min(p.x, q.x), y: min(p.y, q.y), width: abs(p.x - q.x), height: abs(p.y - q.y)))
        guard r.width >= minSize, r.height >= minSize else { return nil }
        return r
    }

    /// 大きさを変えずに動かす。ディスプレイの端で止める
    static func moved(_ r: CGRect, by d: CGSize, in bounds: CGRect) -> CGRect {
        var x = r.minX + d.width, y = r.minY + d.height
        x = min(max(x, bounds.minX), bounds.maxX - r.width)
        y = min(max(y, bounds.minY), bounds.maxY - r.height)
        return rounded(CGRect(x: x, y: y, width: r.width, height: r.height))
    }

    /// ハンドルを `p` まで引いたときの範囲。反対側の辺は動かさない。最小サイズより小さくはしない（裏返らない）
    static func resized(_ r: CGRect, handle: Handle, to p: CGPoint, in bounds: CGRect) -> CGRect {
        let p = clamp(p, to: bounds)
        var minX = r.minX, maxX = r.maxX, minY = r.minY, maxY = r.maxY
        switch handle {
        case .left, .topLeft, .bottomLeft: minX = min(p.x, maxX - minSize)
        case .right, .topRight, .bottomRight: maxX = max(p.x, minX + minSize)
        default: break
        }
        switch handle {
        case .bottom, .bottomLeft, .bottomRight: minY = min(p.y, maxY - minSize)
        case .top, .topLeft, .topRight: maxY = max(p.y, minY + minSize)
        default: break
        }
        return rounded(CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY))
    }

    /// 幅・高さの数値入力を反映する。左上（左下原点では minX と maxY）を固定し、ディスプレイに収まるよう切り詰める
    static func withSize(_ r: CGRect, width: CGFloat, height: CGFloat, in bounds: CGRect) -> CGRect {
        let w = min(max(width.rounded(), minSize), bounds.maxX - r.minX)
        let h = min(max(height.rounded(), minSize), r.maxY - bounds.minY)
        return rounded(CGRect(x: r.minX, y: r.maxY - h, width: w, height: h))
    }

    /// ツールバーの左下の位置。範囲の下 → 上 → 範囲の内側の下端、の順に置けるところへ。横は範囲の中央に揃え、ディスプレイからはみ出させない
    static func toolbarOrigin(selection s: CGRect, toolbar t: CGSize, bounds: CGRect,
                              gap: CGFloat = 12, margin: CGFloat = 8) -> CGPoint {
        var x = (s.midX - t.width / 2).rounded()
        x = min(max(x, bounds.minX + margin), bounds.maxX - margin - t.width)
        let below = s.minY - gap - t.height
        let above = s.maxY + gap
        let y: CGFloat
        if below >= bounds.minY + margin {
            y = below
        } else if above + t.height <= bounds.maxY - margin {
            y = above
        } else {
            y = min(max(s.minY + gap, bounds.minY + margin), bounds.maxY - margin - t.height)
        }
        return CGPoint(x: x, y: y.rounded())
    }

    /// 左下原点のローカル座標を、ディスプレイ内の左上原点（ScreenCaptureKit の sourceRect・`LastRegion`）にする
    static func topLeft(_ r: CGRect, boundsHeight: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: boundsHeight - r.maxY, width: r.width, height: r.height)
    }

    /// 左上原点の範囲を、ディスプレイのグローバル座標（AppKit の左下原点）にする。録画中の枠を置くのに使う
    static func global(_ topLeftRect: CGRect, screenFrame f: CGRect) -> CGRect {
        CGRect(x: f.minX + topLeftRect.minX, y: f.maxY - topLeftRect.maxY,
               width: topLeftRect.width, height: topLeftRect.height)
    }

    /// 整数ポイントに丸める（Retina のマウス座標は 0.5pt などの端数になる）。辺の位置を丸めるので、大きさも整数になる
    static func rounded(_ r: CGRect) -> CGRect {
        let minX = r.minX.rounded(), minY = r.minY.rounded()
        return CGRect(x: minX, y: minY, width: r.maxX.rounded() - minX, height: r.maxY.rounded() - minY)
    }

    private static func clamp(_ p: CGPoint, to b: CGRect) -> CGPoint {
        CGPoint(x: min(max(p.x, b.minX), b.maxX), y: min(max(p.y, b.minY), b.maxY))
    }
}
