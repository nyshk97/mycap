import AppKit
import ImageIO
import UniformTypeIdentifiers

/// 整形の設定の保存（前回の設定を覚える）と、整形した画像の書き出し
enum StyleService {
    private static let defaultsKey = "styleSettings"

    static var settings: StyleSettings {
        get {
            guard let data = UserDefaults.standard.data(forKey: defaultsKey),
                  let s = try? JSONDecoder().decode(StyleSettings.self, from: data) else { return StyleSettings() }
            return s
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: defaultsKey)
            }
        }
    }

    /// 画像と、そのピクセル / ポイントの倍率（Retina の撮影なら 2）
    static func load(_ url: URL) -> (CGImage, CGFloat)? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let dpi = (props?[kCGImagePropertyDPIWidth] as? Double) ?? 72
        return (image, CGFloat(max(dpi / 72, 1)))
    }

    /// `<元の名前>_styled.png` を元と同じフォルダに書く（同名があれば `_2`…）。書けたら URL を返す
    static func export(_ source: URL, settings: StyleSettings, to explicit: URL? = nil) -> URL? {
        guard let (image, scale) = load(source), let out = StyleRenderer.render(image, scale: scale, settings: settings) else {
            Log.write("style.render_failed path=\(source.path)")
            return nil
        }
        let dest: URL
        if let explicit {
            dest = explicit
        } else {
            let dir = source.deletingLastPathComponent()
            let name = FileNaming.uniqueName(stem: source.deletingPathExtension().lastPathComponent + "_styled", ext: "png") {
                FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path)
            }
            dest = dir.appendingPathComponent(name)
        }
        guard let d = CGImageDestinationCreateWithURL(dest as CFURL, UTType.png.identifier as CFString, 1, nil) else { return nil }
        let dpi = 72 * scale
        CGImageDestinationAddImage(d, out, [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary)
        guard CGImageDestinationFinalize(d) else { return nil }
        Log.write("style.exported name=\(dest.lastPathComponent) px=\(out.width)x\(out.height) bg=\(settings.background.rawValue) padding=\(settings.padding) corner=\(settings.cornerRadius) shadow=\(settings.shadow)")
        return dest
    }
}
