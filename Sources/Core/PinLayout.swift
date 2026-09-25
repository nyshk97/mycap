import CoreGraphics

/// ピン留めの初期位置と、リサイズできる倍率の範囲（純粋関数）。座標は AppKit のグローバル座標
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
}
