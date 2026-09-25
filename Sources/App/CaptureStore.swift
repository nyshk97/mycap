import Foundation

/// 撮ったものの置き場。撮った直後はキャッシュに置くだけで、サムネイルの「保存」を押したときに ~/Downloads へコピーする
enum CaptureStore {
    /// 一時ファイルをキャッシュへ `YYYY-MM-DD_HH-mm-ss.<ext>` の名前で移す
    static func keep(_ tmp: URL) -> URL? {
        place(tmp, in: Env.cacheDir, move: true)
    }

    /// キャッシュのファイルを保存先（~/Downloads）へコピーする。同じ名前があれば `_2`…
    static func save(_ url: URL) -> URL? {
        place(url, in: Env.saveDir, move: false, stem: url.deletingPathExtension().lastPathComponent)
    }

    /// 起動時に 24 時間より古いキャッシュを消す
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
