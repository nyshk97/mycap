import CoreGraphics
import Foundation

/// 録画の出力サイズと経過時間の表示（純粋関数）
enum RecordingFormat {
    /// H.264 が扱える幅・高さの上限
    static let maxDimension: CGFloat = 4096
    static let fps: Int32 = 30

    /// 論理解像度（1x）で撮る。H.264 のため偶数に丸め、4096 を超えるなら縦横比を保って縮める
    static func outputSize(points: CGSize) -> (width: Int, height: Int) {
        guard points.width > 0, points.height > 0 else { return (2, 2) }
        let k = min(1, maxDimension / max(points.width, points.height))
        func even(_ v: CGFloat) -> Int { max(2, Int((v * k / 2).rounded(.down)) * 2) }
        return (even(points.width), even(points.height))
    }

    /// メニューバーの経過時間。`0:07` / `12:34` / `1:02:03`
    static func elapsed(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
}
