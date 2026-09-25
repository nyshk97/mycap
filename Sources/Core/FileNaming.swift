import Foundation

/// 保存ファイル名の規則（純粋関数）。`2026-09-25_18-54-12.png`、同じ秒に重なったら `_2`、`_3` …
/// 空白と全角を含めないのは、ターミナル・Claude Code にパスを渡すときにクォートを要らなくするため
enum FileNaming {
    static func stem(for date: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f.string(from: date)
    }

    /// `exists` がファイル名（拡張子込み）の存在を答える。最初に空いている名前を返す
    static func uniqueName(stem: String, ext: String, exists: (String) -> Bool) -> String {
        let first = "\(stem).\(ext)"
        if !exists(first) { return first }
        var n = 2
        while exists("\(stem)_\(n).\(ext)") { n += 1 }
        return "\(stem)_\(n).\(ext)"
    }
}
