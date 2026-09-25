import CoreGraphics

/// ピン留めの初期位置と拡大縮小（純粋関数）。座標は AppKit のグローバル座標
enum PinLayout {
    /// 画面の visibleFrame に対して、これより大きければ縮小する割合
    static let fitRatio: CGFloat = 0.9
    static let minScale: CGFloat = 0.1
    static let maxScale: CGFloat = 4

    /// 実寸（ポイント）で、画面より大きければ収まるまで縮小して中央に置く
    static func initialFrame(image: CGSize, visible: CGRect) -> CGRect {
        let limit = CGSize(width: visible.width * fitRatio, height: visible.height * fitRatio)
        let scale = min(limit.width / image.width, limit.height / image.height, 1)
        let size = CGSize(width: (image.width * scale).rounded(), height: (image.height * scale).rounded())
        return CGRect(x: (visible.midX - size.width / 2).rounded(), y: (visible.midY - size.height / 2).rounded(),
                      width: size.width, height: size.height)
    }

    /// 倍率を掛けたあとの枠。`anchor`（マウス位置）を動かさずに拡大縮小する。倍率は実寸に対して min〜max に収める
    static func scaled(frame: CGRect, image: CGSize, by factor: CGFloat, anchor: CGPoint) -> CGRect {
        let current = frame.width / image.width
        let next = min(max(current * factor, minScale), maxScale)
        let size = CGSize(width: (image.width * next).rounded(), height: (image.height * next).rounded())
        // anchor の枠内での相対位置を保つ
        let rx = frame.width > 0 ? (anchor.x - frame.minX) / frame.width : 0.5
        let ry = frame.height > 0 ? (anchor.y - frame.minY) / frame.height : 0.5
        return CGRect(x: (anchor.x - rx * size.width).rounded(), y: (anchor.y - ry * size.height).rounded(),
                      width: size.width, height: size.height)
    }
}
