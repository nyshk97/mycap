import Foundation

/// キャプチャ履歴（キャッシュに残っている撮影結果の一覧）の並べ方と表示の文言（純粋関数）
enum CaptureHistory {
    enum Kind: String, CaseIterable {
        case screenshots, videos

        var title: String {
            switch self {
            case .screenshots: "Screenshots"
            case .videos: "Videos"
            }
        }

        /// 拡張子から種別を決める。キャッシュには png（静止画・整形の出力）と mp4（録画）しか置かない
        static func of(ext: String) -> Kind? {
            switch ext.lowercased() {
            case "png": .screenshots
            case "mp4": .videos
            default: nil
            }
        }
    }

    struct Entry: Equatable {
        let name: String
        let created: Date
    }

    /// 種別で絞り込み、新しい順に並べる。同じ時刻なら名前の降順（`_2` を先に）
    static func items(_ files: [Entry], kind: Kind) -> [Entry] {
        files
            .filter { Kind.of(ext: ($0.name as NSString).pathExtension) == kind }
            .sorted { $0.created != $1.created ? $0.created > $1.created : $0.name > $1.name }
    }

    /// `just now` / `1 minute ago` / `23 minutes ago` / `11 hours ago` / `2 days ago`
    static func relativeAge(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        func unit(_ n: Int, _ word: String) -> String { n == 1 ? "1 \(word) ago" : "\(n) \(word)s ago" }
        if s < 60 { return "just now" }
        if s < 3600 { return unit(s / 60, "minute") }
        if s < 86400 { return unit(s / 3600, "hour") }
        return unit(s / 86400, "day")
    }

    /// 動画の長さのバッジ。`0s` / `2s` / `59s` / `1:05` / `1:02:03`
    static func durationLabel(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded()))
        if s < 60 { return "\(s)s" }
        return RecordingFormat.elapsed(TimeInterval(s))
    }

    /// ←→ でのフォーカス移動。端では止まる（回り込まない）。空なら nil、未選択から動かしたら先頭
    static func moveFocus(_ current: Int?, by delta: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let current else { return 0 }
        return min(max(current + delta, 0), count - 1)
    }
}
