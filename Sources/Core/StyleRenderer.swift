import CoreGraphics
import Foundation

/// 背景と余白の整形（純粋関数。CoreGraphics だけで描くのでテストで画素まで確かめられる）
struct StyleSettings: Codable, Equatable {
    enum Background: String, Codable, CaseIterable {
        case sunset, ocean, mint, dusk, plain, transparent
    }

    var background: Background = .ocean
    /// 余白（ポイント）
    var padding: Double = 48
    /// 画像の角丸（ポイント）
    var cornerRadius: Double = 10
    var shadow: Bool = true

    static let paddingRange: ClosedRange<Double> = 0...160
    static let cornerRange: ClosedRange<Double> = 0...40
}

enum StyleRenderer {
    /// 背景の色（sRGB, 0〜1）。グラデーションは左上 → 右下
    static func colors(_ bg: StyleSettings.Background) -> [(CGFloat, CGFloat, CGFloat)] {
        switch bg {
        case .sunset: return [(0.99, 0.72, 0.45), (0.93, 0.38, 0.52)]
        case .ocean: return [(0.36, 0.62, 0.98), (0.55, 0.36, 0.93)]
        case .mint: return [(0.60, 0.93, 0.78), (0.24, 0.66, 0.72)]
        case .dusk: return [(0.22, 0.24, 0.36), (0.55, 0.36, 0.52)]
        case .plain: return [(0.95, 0.94, 0.92)]
        case .transparent: return []
        }
    }

    /// 出力のピクセルサイズ。`scale` は画像のピクセル / ポイント（Retina の撮影なら 2）
    static func outputSize(imagePixels: CGSize, scale: CGFloat, settings: StyleSettings) -> CGSize {
        let pad = (CGFloat(settings.padding) * scale).rounded()
        return CGSize(width: imagePixels.width + pad * 2, height: imagePixels.height + pad * 2)
    }

    static func render(_ image: CGImage, scale: CGFloat, settings: StyleSettings) -> CGImage? {
        let imageSize = CGSize(width: image.width, height: image.height)
        let size = outputSize(imagePixels: imageSize, scale: scale, settings: settings)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let full = CGRect(origin: .zero, size: size)

        let stops = colors(settings.background)
        if stops.count == 1 {
            ctx.setFillColor(CGColor(srgbRed: stops[0].0, green: stops[0].1, blue: stops[0].2, alpha: 1))
            ctx.fill(full)
        } else if stops.count >= 2 {
            let cgColors = stops.map { CGColor(srgbRed: $0.0, green: $0.1, blue: $0.2, alpha: 1) } as CFArray
            let gradient = CGGradient(colorsSpace: space, colors: cgColors, locations: nil)!
            // CGContext は左下原点。左上 → 右下
            ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size.height), end: CGPoint(x: size.width, y: 0), options: [])
        }

        let pad = (size.width - imageSize.width) / 2
        let rect = CGRect(x: pad, y: pad, width: imageSize.width, height: imageSize.height)
        let radius = min(CGFloat(settings.cornerRadius) * scale, min(rect.width, rect.height) / 2)
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

        if settings.shadow {
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -10 * scale), blur: 30 * scale,
                          color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.35))
            ctx.addPath(path)
            ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
            ctx.fillPath()
            ctx.restoreGState()
        }
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.draw(image, in: rect)
        ctx.restoreGState()
        return ctx.makeImage()
    }
}
