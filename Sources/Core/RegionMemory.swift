import CoreGraphics

/// 「前回と同じ範囲」を撮るための範囲の確定と座標変換（純粋関数）。
/// `screencapture -i` は選んだ矩形を返さないので、ドラッグの始点・終点から矩形を作り、撮れた画像のピクセル数と突き合わせて確かめる
enum RegionMemory {
    /// 画像のピクセル数とドラッグの矩形（×scale）のずれの許容（ピクセル）。端数の丸め分
    static let tolerance: CGFloat = 4

    /// ドラッグの測り残しの許容（画像の大きさに対する割合）。
    /// ボタンを押した瞬間の検出はポーリングなので遅れ、始点が終点側に数十ポイントずれる（実測で約 4.5%）
    static let shortfallRatio: CGFloat = 0.25

    /// ドラッグの始点・終点（AppKit のグローバル座標）から範囲を作る。
    /// 大きさは撮れた画像のピクセル数を正とし、位置は終点（離した点。マウスが止まっているので正確）とドラッグの向きで決める。
    /// ドラッグが画像より大きい・小さすぎるときは nil（Space でウィンドウを撮った・クリックだけ等）
    static func rect(from a: CGPoint, to b: CGPoint, imagePixels: CGSize, scale: CGFloat) -> CGRect? {
        let dragged = CGSize(width: abs(a.x - b.x), height: abs(a.y - b.y))
        let size = CGSize(width: imagePixels.width / scale, height: imagePixels.height / scale)
        let slack = tolerance / scale
        guard dragged.width >= 1, dragged.height >= 1 else { return nil }
        guard dragged.width <= size.width + slack, dragged.height <= size.height + slack,
              dragged.width >= size.width * (1 - shortfallRatio) - slack,
              dragged.height >= size.height * (1 - shortfallRatio) - slack else { return nil }
        let x = b.x >= a.x ? b.x - size.width : b.x
        let y = b.y >= a.y ? b.y - size.height : b.y
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// グローバル座標の範囲を、ディスプレイ内の左上原点の座標（ScreenCaptureKit の sourceRect）にする。
    /// ディスプレイからはみ出していれば nil
    static func local(_ rect: CGRect, in screenFrame: CGRect) -> CGRect? {
        guard screenFrame.insetBy(dx: -1, dy: -1).contains(rect) else { return nil }
        let r = rect.intersection(screenFrame)
        return CGRect(x: r.minX - screenFrame.minX, y: screenFrame.maxY - r.maxY, width: r.width, height: r.height)
    }
}
