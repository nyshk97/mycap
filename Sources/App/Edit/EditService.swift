import AppKit
import ImageIO
import UniformTypeIdentifiers

/// 編集する画像の読み込みと、注釈を焼き込んだ画像の書き出し
enum EditService {
    /// 画像と、そのピクセル / ポイントの倍率（Retina の撮影なら 2）
    static func load(_ url: URL) -> (CGImage, CGFloat)? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let dpi = (props?[kCGImagePropertyDPIWidth] as? Double) ?? 72
        return (image, CGFloat(max(dpi / 72, 1)))
    }

    /// `<元の名前>_edited.png` を元と同じフォルダ（キャッシュ）に書く（同名があれば `_2`…）。書けたら URL を返す。
    /// DPI（Retina の倍率）と撮ったときの前面アプリは元の画像から引き継ぐ
    static func export(_ source: URL, annotations: [Annotation], to explicit: URL? = nil) -> URL? {
        guard let (image, scale) = load(source), let out = AnnotationRenderer.render(image, annotations: annotations) else {
            Log.write("edit.render_failed path=\(source.path)")
            return nil
        }
        let dest: URL
        if let explicit {
            dest = explicit
        } else {
            let dir = source.deletingLastPathComponent()
            let name = FileNaming.uniqueName(stem: FileNaming.editedStem(for: source.lastPathComponent), ext: "png") {
                FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path)
            }
            dest = dir.appendingPathComponent(name)
        }
        guard let d = CGImageDestinationCreateWithURL(dest as CFURL, UTType.png.identifier as CFString, 1, nil) else { return nil }
        let dpi = 72 * scale
        CGImageDestinationAddImage(d, out, [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary)
        guard CGImageDestinationFinalize(d) else { return nil }
        CaptureStore.copySourceApp(from: source, to: dest)
        let kinds = Dictionary(grouping: annotations, by: \.kind.rawValue).map { "\($0.key)=\($0.value.count)" }.sorted().joined(separator: ",")
        Log.write("edit.exported name=\(dest.lastPathComponent) px=\(out.width)x\(out.height) annotations=\(annotations.count) kinds=\(kinds)")
        return dest
    }
}
