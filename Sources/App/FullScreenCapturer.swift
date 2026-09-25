import AppKit
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

/// 全画面（マウスのあるディスプレイ）を ScreenCaptureKit で撮る。
/// `screencapture -D <n>` の番号と NSScreen の対応はマルチディスプレイで確かめにくいので、ディスプレイ ID で引ける SCK にした。
/// mycap 自身のウィンドウ（サムネイル・トースト）は写さない。ただし `keep`（デスクトップアイコンを隠す壁紙カバー）は写す
enum FullScreenCapturer {
    static func capture(screen: NSScreen, keep: [Int] = [], completion: @escaping (URL?) -> Void) {
        let id = screen.displayID
        func finish(_ url: URL?) { DispatchQueue.main.async { completion(url) } }
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
            guard let content, let display = content.displays.first(where: { $0.displayID == id }) else {
                Log.write("capture.full.no_display id=\(id) error=\(String(describing: error))")
                return finish(nil)
            }
            let mine = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
            let keepIDs = Set(keep.map { CGWindowID($0) })
            let excepting = content.windows.filter { keepIDs.contains($0.windowID) }
            let filter = SCContentFilter(display: display, excludingApplications: mine, exceptingWindows: excepting)
            let scale = CGFloat(filter.pointPixelScale)
            let config = SCStreamConfiguration()
            config.width = Int(filter.contentRect.width * scale)
            config.height = Int(filter.contentRect.height * scale)
            config.showsCursor = false
            config.captureResolution = .best
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) { image, error in
                guard let image else {
                    Log.write("capture.full.failed error=\(String(describing: error))")
                    return finish(nil)
                }
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("mycap-\(UUID().uuidString).png")
                finish(writePNG(image, scale: scale, to: url) ? url : nil)
            }
        }
    }

    /// DPI を 72×scale にしておく（screencapture の出力と同じく、プレビュー等でポイントサイズで開く）
    private static func writePNG(_ image: CGImage, scale: CGFloat, to url: URL) -> Bool {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return false }
        let dpi = 72 * scale
        CGImageDestinationAddImage(dest, image, [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary)
        return CGImageDestinationFinalize(dest)
    }
}
