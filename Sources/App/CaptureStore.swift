import AppKit

/// 撮ったものの置き場。撮った直後はキャッシュに置くだけで、サムネイルの「保存」を押したときに ~/Downloads へコピーする
enum CaptureStore {
    /// 一時ファイルをキャッシュへ `YYYY-MM-DD_HH-mm-ss.<ext>` の名前で移す。
    /// `app` は撮った瞬間に前面だったアプリの bundle id（キャプチャ履歴のアイコンに使う）
    static func keep(_ tmp: URL, app: String?) -> URL? {
        guard let kept = place(tmp, in: Env.cacheDir, move: true) else { return nil }
        // 履歴の「N minutes ago」と掃除の基準。一時ファイルの作成時刻（録画の開始時など）でなく、置いた時刻にそろえる
        let now = Date()
        try? FileManager.default.setAttributes([.creationDate: now, .modificationDate: now], ofItemAtPath: kept.path)
        if let app { setSourceApp(app, of: kept) }
        return kept
    }

    /// キャッシュのファイルを保存先（~/Downloads）へコピーする。同じ名前があれば `_2`…
    static func save(_ url: URL) -> URL? {
        place(url, in: Env.saveDir, move: false, stem: url.deletingPathExtension().lastPathComponent)
    }

    /// 7 日（`CacheRetention.maxAge`）より古いキャッシュを消す。起動時と、起動しっぱなしでも 1 日 1 回
    static func purge() {
        let fm = FileManager.default
        let dir = Env.cacheDir
        let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        let files = names.compactMap { name -> (name: String, modified: Date)? in
            guard let date = (try? fm.attributesOfItem(atPath: dir.appendingPathComponent(name).path))?[.modificationDate] as? Date
            else { return nil }
            return (name, date)
        }
        let expired = CacheRetention.expired(files, now: Date())
        for name in expired { try? fm.removeItem(at: dir.appendingPathComponent(name)) }
        Log.write("cache.purged removed=\(expired.count) kept=\(files.count - expired.count) dir=\(dir.path)")
    }

    /// キャッシュのファイル（名前・撮った時刻）。キャプチャ履歴の元。
    /// 時刻は名前から取る（`--ingest` のコピー等は作成日時が元ファイルのものになるため）。編集の出力など名前から取れないものだけ作成日時
    static func entries() -> [CaptureHistory.Entry] {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: Env.cacheDir.path)) ?? []
        return names.compactMap { name in
            if let date = FileNaming.date(fromName: name) { return CaptureHistory.Entry(name: name, created: date) }
            let attrs = try? fm.attributesOfItem(atPath: Env.cacheDir.appendingPathComponent(name).path)
            guard let date = (attrs?[.creationDate] ?? attrs?[.modificationDate]) as? Date else { return nil }
            return CaptureHistory.Entry(name: name, created: date)
        }
    }

    // MARK: - 撮ったときに前面だったアプリ（拡張属性に持つ）

    private static let sourceAppKey = "io.github.nyshk97.mycap.source-app"

    static func setSourceApp(_ bundleID: String, of url: URL) {
        let data = Array(bundleID.utf8)
        let rc = setxattr(url.path, sourceAppKey, data, data.count, 0, 0)
        if rc != 0 { Log.write("store.xattr_failed path=\(url.path) errno=\(errno)") }
    }

    static func sourceApp(of url: URL) -> String? {
        let size = getxattr(url.path, sourceAppKey, nil, 0, 0, 0)
        guard size > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard getxattr(url.path, sourceAppKey, &buf, size, 0, 0) == size else { return nil }
        return String(decoding: buf, as: UTF8.self)
    }

    /// 編集の出力に元画像のアプリを引き継ぐ
    static func copySourceApp(from src: URL, to dest: URL) {
        if let app = sourceApp(of: src) { setSourceApp(app, of: dest) }
    }

    /// 撮り始める時点の前面アプリ。自分自身（メニューから撮ったとき等）は記録しない
    static func frontmostAppID() -> String? {
        let front = NSWorkspace.shared.frontmostApplication
        guard front?.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        return front?.bundleIdentifier
    }

    private static func place(_ src: URL, in dir: URL, move: Bool, stem: String? = nil) -> URL? {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let name = FileNaming.uniqueName(stem: stem ?? FileNaming.stem(for: Date()), ext: src.pathExtension.lowercased()) {
                fm.fileExists(atPath: dir.appendingPathComponent($0).path)
            }
            let dest = dir.appendingPathComponent(name)
            if move { try fm.moveItem(at: src, to: dest) } else { try fm.copyItem(at: src, to: dest) }
            return dest
        } catch {
            Log.write("store.failed move=\(move) dir=\(dir.path) error=\(error)")
            return nil
        }
    }
}
