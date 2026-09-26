import CoreGraphics

/// 「前回と同じ範囲」を撮るための範囲の確定と座標変換（純粋関数）。
/// `screencapture -i` は選んだ矩形を返さないので、ドラッグの始点・終点から矩形を作り、撮れた画像のピクセル数と突き合わせて確かめる
enum RegionMemory {
    /// 画像のピクセル数とドラッグの矩形（×scale）のずれの許容（ピクセル）。端数の丸め分
    static let tolerance: CGFloat = 4

    /// ドラッグの始点・終点（AppKit のグローバル座標）から範囲を作る。
    /// 撮れた画像と大きさが合わなければ nil（Space でウィンドウを撮った・クリックだけ等）
    static func rect(from a: CGPoint, to b: CGPoint, imagePixels: CGSize, scale: CGFloat) -> CGRect? {
        let r = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
        guard r.width >= 1, r.height >= 1 else { return nil }
        guard abs(r.width * scale - imagePixels.width) <= tolerance,
              abs(r.height * scale - imagePixels.height) <= tolerance else { return nil }
        return r
    }

    /// グローバル座標の範囲を、ディスプレイ内の左上原点の座標（ScreenCaptureKit の sourceRect）にする。
    /// ディスプレイからはみ出していれば nil
    static func local(_ rect: CGRect, in screenFrame: CGRect) -> CGRect? {
        guard screenFrame.insetBy(dx: -1, dy: -1).contains(rect) else { return nil }
        let r = rect.intersection(screenFrame)
        return CGRect(x: r.minX - screenFrame.minX, y: screenFrame.maxY - r.maxY, width: r.width, height: r.height)
    }
}
