import Foundation

/// dev 版（mycap Dev）と常用版で変わる値をまとめる
enum Env {
    #if DEBUG
    static let isDev = true
    static let logFileName = "mycap-dev.log"
    static let cacheDirName = "mycap-dev"
    #else
    static let isDev = false
    static let logFileName = "mycap.log"
    static let cacheDirName = "mycap"
    #endif

    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    static var versionLabel: String {
        isDev ? "mycap v\(version) (dev)" : "mycap v\(version)"
    }

    /// 撮った直後の置き場（サムネイルで「保存」を押すまで）。dev と常用で分ける
    static let cacheDir: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(cacheDirName, isDirectory: true)

    /// サムネイルで「保存」を押したときの保存先（固定値。CleanShot X と同じ ~/Downloads）。
    /// dev 版だけ `MYCAP_SAVE_DIR` で差し替えられる（検証で ~/Downloads を汚さないため）
    static let saveDir: URL = {
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["MYCAP_SAVE_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        #endif
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    }()

    /// 撮った直後のサムネイルがキーを受ける「待ち受け」の長さ（秒）。dev 版だけ `MYCAP_ARM_SECONDS` で短くできる
    static let armSeconds: TimeInterval = {
        #if DEBUG
        if let v = ProcessInfo.processInfo.environment["MYCAP_ARM_SECONDS"].flatMap(Double.init), v > 0 { return v }
        #endif
        return 5
    }()

    /// 待ち受けでキー（Esc・⌘C 等）を取るか。dev 版だけ `MYCAP_ARM_KEYS=0` で取らない
    /// （検証フックでサムネイルを出すたびに、ユーザーの ⌘C / Esc / ⌘S を奪わないため）
    static let armKeys: Bool = {
        #if DEBUG
        return ProcessInfo.processInfo.environment["MYCAP_ARM_KEYS"] != "0"
        #else
        return true
        #endif
    }()

    static let logURL: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/mycap", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(logFileName)
    }()
}
