import Foundation

/// 録画のサムネイルの左下に出す「長さ · 大きさ」（純粋関数）
enum VideoInfoText {
    /// `0:12 · 2.4 MB`。長さは録画中のバーと同じ書き方（端数は四捨五入。1 秒未満の録画でも 0:01 にならず 0:00 のまま）
    static func label(seconds: TimeInterval, bytes: Int64) -> String {
        "\(RecordingFormat.elapsed(seconds.rounded())) · \(size(bytes))"
    }

    /// Finder と同じ 1000 進。1 MB 未満は KB の整数、それ以上は小数 1 桁（10 MB 以上は整数）。地域設定に依らず小数点は `.`
    static func size(_ bytes: Int64) -> String {
        let b = Double(max(0, bytes))
        if b < 1000 { return "\(Int(b)) B" }
        if b < 1_000_000 { return "\(Int((b / 1000).rounded())) KB" }
        let units = ["MB", "GB"]
        var v = b / 1_000_000
        var i = 0
        while v >= 1000, i < units.count - 1 {
            v /= 1000
            i += 1
        }
        return v >= 10 ? "\(Int(v.rounded())) \(units[i])" : "\(String(format: "%.1f", v)) \(units[i])"
    }
}
