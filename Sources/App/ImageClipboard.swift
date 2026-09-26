import AppKit

/// 画像ファイルの中身をクリップボードに載せる。PNG と TIFF の両方を持たせる
/// （Slack・ブラウザは PNG、古い AppKit アプリは TIFF を読む）
enum ImageClipboard {
    @discardableResult
    static func copy(_ url: URL) -> Bool {
        guard let png = try? Data(contentsOf: url), let tiff = NSImage(data: png)?.tiffRepresentation else {
            Log.write("clipboard.copy_failed path=\(url.path)")
            return false
        }
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        item.setData(tiff, forType: .tiff)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([item])
        Log.write("clipboard.copied name=\(url.lastPathComponent)")
        return true
    }

    /// 録画はファイルそのもの（Finder の ⌘C と同じ file URL）を載せる。Slack・Finder・メールに ⌘V で貼れる
    static func copyFile(_ url: URL) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([url as NSURL])
        Log.write("clipboard.copied_file name=\(url.lastPathComponent)")
    }
}
