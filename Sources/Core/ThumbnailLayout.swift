import CoreGraphics

/// 撮影後のサムネイルの大きさと積み方（純粋関数）。座標は AppKit のグローバル座標（原点は主画面の左下、y は上向き）
enum ThumbnailLayout {
    /// 画像を収める箱。内蔵 1 枚（visibleFrame の高さ 880pt 前後）でも 5 枚積めるように高さを抑える
    static let maxBox = CGSize(width: 240, height: 150)
    /// ホバーのボタンが並ぶ最小の大きさ。極端に横長・縦長の画像はこの枠の中に余白付きで収める
    static let minPanel = CGSize(width: 160, height: 96)
    static let margin: CGFloat = 16
    static let spacing: CGFloat = 12
    static let maxCount = 5

    /// 画像のポイントサイズからサムネイルの大きさを出す。拡大はしない（小さい画像がぼやけるため）
    static func panelSize(for image: CGSize) -> CGSize {
        guard image.width > 0, image.height > 0 else { return minPanel }
        let scale = min(maxBox.width / image.width, maxBox.height / image.height, 1)
        let fitted = CGSize(width: (image.width * scale).rounded(), height: (image.height * scale).rounded())
        return CGSize(width: max(fitted.width, minPanel.width), height: max(fitted.height, minPanel.height))
    }

    /// `sizes[0]` が最新。最新を画面の左下に置き、古いものほど上へ積む
    static func frames(visible: CGRect, sizes: [CGSize]) -> [CGRect] {
        var y = visible.minY + margin
        return sizes.map { size in
            let frame = CGRect(x: visible.minX + margin, y: y, width: size.width, height: size.height)
            y += size.height + spacing
            return frame
        }
    }

    /// サムネイルから出した通知（コピーしました等）の置き場所。サムネイルの右隣に縦の中央をそろえ、画面からはみ出さないよう寄せる
    static func toastOrigin(anchor: CGRect, size: CGSize, visible: CGRect) -> CGPoint {
        let x = min(anchor.maxX + spacing, visible.maxX - size.width)
        let y = min(max(anchor.midY - size.height / 2, visible.minY), visible.maxY - size.height)
        return CGPoint(x: max(x, visible.minX), y: y)
    }

    /// 最新が先頭の並びで `count` 枚あるとき、閉じるべき古いものの数
    static func overflow(count: Int) -> Int {
        max(0, count - maxCount)
    }
}
