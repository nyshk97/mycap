import AppKit
import SwiftUI

/// 整形パネル。背景・余白・角丸・影を選んでプレビューし、Enter で `_styled.png` を保存してコピーする
final class StylePanelController {
    private var panel: NSPanel?
    private var model: StyleModel?
    /// 書き出した画像を受け取る（サムネイルを出す）
    var onExported: ((URL) -> Void)?

    func open(_ url: URL, activate: Bool = true) {
        close()
        guard let (image, scale) = StyleService.load(url) else {
            Log.write("style.load_failed path=\(url.path)")
            return
        }
        let model = StyleModel(source: url, image: image, scale: scale)
        model.onSave = { [weak self] in self?.save() }
        model.onCancel = { [weak self] in self?.close() }
        self.model = model

        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
                        styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        p.title = "整形"
        p.titlebarAppearsTransparent = true
        p.isReleasedWhenClosed = false
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = NSHostingView(rootView: StyleView(model: model))
        let screen = NSScreen.underMouse.visibleFrame
        p.setFrameOrigin(NSPoint(x: screen.midX - p.frame.width / 2, y: screen.midY - p.frame.height / 2))
        if activate {
            NSApp.activate(ignoringOtherApps: true)
            p.makeKeyAndOrderFront(nil)
        } else {
            p.orderFrontRegardless()
        }
        panel = p
        Log.write("style.opened name=\(url.lastPathComponent)")
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
        model = nil
    }

    private func save() {
        guard let model else { return }
        let settings = model.settings
        StyleService.settings = settings
        close()
        guard let out = StyleService.export(model.source, settings: settings) else {
            Toast.shared.show("整形した画像を保存できませんでした")
            return
        }
        ImageClipboard.copy(out)
        onExported?(out)
    }

    // MARK: - 検証フック用

    func snapshot(to path: String) -> Bool {
        guard let view = panel?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: path))) != nil
    }
}

final class StyleModel: ObservableObject {
    let source: URL
    private let previewSource: CGImage
    private let previewScale: CGFloat
    @Published var settings: StyleSettings { didSet { renderPreview() } }
    @Published private(set) var preview: NSImage?
    var onSave: (() -> Void)?
    var onCancel: (() -> Void)?

    init(source: URL, image: CGImage, scale: CGFloat) {
        self.source = source
        // プレビューは縮小した画像で描く（大きな撮影でもスライダーが引っかからないように）
        let maxSide: CGFloat = 900
        let longest = CGFloat(max(image.width, image.height))
        let factor = min(1, maxSide / longest)
        previewSource = Self.downscale(image, factor) ?? image
        previewScale = scale * factor
        settings = StyleService.settings
        renderPreview()
    }

    private func renderPreview() {
        guard let out = StyleRenderer.render(previewSource, scale: previewScale, settings: settings) else { return }
        preview = NSImage(cgImage: out, size: NSSize(width: out.width, height: out.height))
    }

    private static func downscale(_ image: CGImage, _ factor: CGFloat) -> CGImage? {
        guard factor < 1 else { return image }
        let w = Int(CGFloat(image.width) * factor), h = Int(CGFloat(image.height) * factor)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}

private struct StyleView: View {
    @ObservedObject var model: StyleModel

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Checkerboard()
                if let preview = model.preview {
                    Image(nsImage: preview).resizable().aspectRatio(contentMode: .fit)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 260, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            HStack(spacing: 10) {
                ForEach(StyleSettings.Background.allCases, id: \.self) { bg in
                    Swatch(background: bg, selected: model.settings.background == bg)
                        .onTapGesture { model.settings.background = bg }
                }
                Spacer()
                Toggle("影", isOn: $model.settings.shadow)
            }
            LabeledSlider(title: "余白", value: $model.settings.padding, range: StyleSettings.paddingRange)
            LabeledSlider(title: "角丸", value: $model.settings.cornerRadius, range: StyleSettings.cornerRange)

            HStack {
                Spacer()
                Button("キャンセル") { model.onCancel?() }
                    .keyboardShortcut(.cancelAction)
                Button("保存してコピー") { model.onSave?() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(EdgeInsets(top: 34, leading: 18, bottom: 18, trailing: 18))
        .frame(width: 560, height: 520)
    }
}

private struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        HStack {
            Text(title).frame(width: 36, alignment: .leading)
            Slider(value: $value, in: range)
            Text("\(Int(value))").monospacedDigit().frame(width: 32, alignment: .trailing)
        }
    }
}

private struct Swatch: View {
    let background: StyleSettings.Background
    let selected: Bool

    var body: some View {
        let colors = StyleRenderer.colors(background).map { Color(.sRGB, red: $0.0, green: $0.1, blue: $0.2) }
        ZStack {
            if colors.isEmpty {
                Checkerboard()
            } else if colors.count == 1 {
                colors[0]
            } else {
                LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
        .frame(width: 28, height: 28)
        .clipShape(Circle())
        .overlay(Circle().stroke(selected ? Color.accentColor : Color.secondary.opacity(0.4), lineWidth: selected ? 3 : 1))
        .help(background.rawValue)
    }
}

/// 透明の目印の市松模様
private struct Checkerboard: View {
    var body: some View {
        Canvas { ctx, size in
            let cell: CGFloat = 8
            for y in stride(from: 0, to: size.height, by: cell) {
                for x in stride(from: 0, to: size.width, by: cell) where (Int(x / cell) + Int(y / cell)) % 2 == 0 {
                    ctx.fill(Path(CGRect(x: x, y: y, width: cell, height: cell)), with: .color(.gray.opacity(0.18)))
                }
            }
        }
    }
}
