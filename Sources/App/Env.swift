import Foundation

/// dev 版（mycap Dev）と常用版で変わる値をまとめる
enum Env {
    #if DEBUG
    static let isDev = true
    static let logFileName = "mycap-dev.log"
    #else
    static let isDev = false
    static let logFileName = "mycap.log"
    #endif

    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    static var versionLabel: String {
        isDev ? "mycap v\(version) (dev)" : "mycap v\(version)"
    }

    /// 撮った画像・録画の保存先（固定値。CleanShot X と同じ ~/Downloads）。
    /// dev 版だけ `MYCAP_SAVE_DIR` で差し替えられる（検証で ~/Downloads を汚さないため）
    static let saveDir: URL = {
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["MYCAP_SAVE_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        #endif
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    }()

    static let logURL: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/mycap", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(logFileName)
    }()
}
