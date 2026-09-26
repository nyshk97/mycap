import Foundation

/// open 経由の起動では stdout を捕捉できないため、~/Library/Logs/capit/ に追記する。
/// 先頭の語はイベント名（`launch` `hotkey.registered` 等）で固定し、grep で検証できるようにする
enum Log {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()
    private static let queue = DispatchQueue(label: "capit.log")

    static func write(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        queue.async {
            let path = Env.logURL.path
            if !FileManager.default.fileExists(atPath: path) {
                FileManager.default.createFile(atPath: path, contents: nil)
            }
            guard let handle = FileHandle(forWritingAtPath: path) else { return }
            handle.seekToEndOfFile()
            handle.write(line.data(using: String.Encoding.utf8)!)
            handle.closeFile()
        }
    }
}
