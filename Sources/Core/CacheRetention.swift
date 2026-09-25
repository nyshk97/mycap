import Foundation

/// 撮ったもののキャッシュ（保存を押すまでの置き場）の掃除（純粋関数）。
/// サムネイルを閉じても、ピンの元ファイルとして・うっかり閉じたときの拾い先として、しばらく残す
enum CacheRetention {
    static let maxAge: TimeInterval = 24 * 60 * 60

    /// 消すべきファイル名。更新日時が `now - maxAge` より前のもの
    static func expired(_ files: [(name: String, modified: Date)], now: Date, maxAge: TimeInterval = maxAge) -> [String] {
        files.filter { now.timeIntervalSince($0.modified) > maxAge }.map(\.name)
    }
}
