#!/usr/bin/env swift
import AppKit

// mycast のアプリアイコン（macOS 26 向けフルブリード。角丸・余白・外周の影はシステムが付けるので描かない）。
// デザイン: 暖かい紙の地に黒ガラスの検索ピル、くすんだ 3 色の点（アプリ・クリップボード・絵文字）とクリーム色のキャレット。
// 使い方: swift scripts/make_icon.swift          → Sources/Assets.xcassets/AppIcon.appiconset
//         swift scripts/make_icon.swift --dev    → Sources/Assets.xcassets/AppIconDev.appiconset（DEV の帯付き）
// 生成物の PNG はコミットする（毎ビルドで作らない）。

let dev = CommandLine.arguments.contains("--dev")
let outDir = "Sources/Assets.xcassets/\(dev ? "AppIconDev" : "AppIcon").appiconset"

func color(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

// 紙の粒子。固定シードで毎回同じ PNG になるようにする（再生成で無意味な差分を出さない）
func grainImage(_ px: Int) -> CGImage {
    var seed: UInt64 = 0x6D79_6361_70
    func next() -> UInt64 { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return seed >> 33 }
    var buf = [UInt8](repeating: 0, count: px * px * 4)
    for i in 0..<(px * px) {
        let a = Double(next() % 1000) / 1000 * 0.13   // 粒子 1 粒の濃さ（最大 13%）
        buf[i * 4 + 0] = UInt8(0x59 * a)                // premultiplied の茶色
        buf[i * 4 + 1] = UInt8(0x47 * a)
        buf[i * 4 + 2] = UInt8(0x33 * a)
        buf[i * 4 + 3] = UInt8(255 * a)
    }
    let ctx = CGContext(data: &buf, width: px, height: px, bitsPerComponent: 8, bytesPerRow: px * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    return ctx.makeImage()!
}

func render(_ px: Int) -> NSBitmapImageRep {
    // alpha 無し（noneSkipLast）で作る
    let cg = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: false)
    let s = CGFloat(px)
    // 座標はモック（824 角の上から下への座標）の値で書き、ここで変換する
    let u = s / 824
    func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: x * u, y: s - (y + h) * u, width: w * u, height: h * u)
    }

    // 地: 暖かいオフホワイト
    NSGradient(starting: color(0xFBF8F2), ending: color(0xEBE4D8))!.draw(in: CGRect(x: 0, y: 0, width: s, height: s), angle: -90)
    // 粒子は小さいサイズでは見えずノイズになるだけなので 256px 以上にだけ入れる
    if px >= 256 { cg.draw(grainImage(px), in: CGRect(x: 0, y: 0, width: s, height: s)) }

    // 画面（黒ガラス）＋ 2 段の影
    let screen = rect(122, 150, 580, 524)
    let radius = 96 * u
    let screenPath = CGPath(roundedRect: screen, cornerWidth: radius, cornerHeight: radius, transform: nil)
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -26 * u), blur: 56 * u, color: color(0x4A3A28, 0.26).cgColor)
    cg.addPath(screenPath); cg.setFillColor(color(0x1F1D1B).cgColor); cg.fillPath()
    cg.setShadow(offset: CGSize(width: 0, height: -5 * u), blur: 10 * u, color: color(0x4A3A28, 0.2).cgColor)
    cg.addPath(screenPath); cg.fillPath()
    cg.restoreGState()
    cg.saveGState()
    cg.addPath(screenPath); cg.clip()
    NSGradient(colors: [color(0x3B3835), color(0x1F1D1B), color(0x100F0E)], atLocations: [0, 0.5, 1],
               colorSpace: .sRGB)!.draw(in: screen, angle: -90)
    cg.restoreGState()

    // 画面の縁のハイライト（上が明るく、下にうっすら）
    if px >= 64 {
        let inset = screen.insetBy(dx: 2 * u, dy: 2 * u)
        cg.saveGState()
        cg.addPath(CGPath(roundedRect: inset, cornerWidth: radius - 2 * u, cornerHeight: radius - 2 * u, transform: nil))
        cg.setLineWidth(4 * u)
        cg.replacePathWithStrokedPath()
        cg.clip()
        NSGradient(colors: [color(0xFFFFFF, 0.45), color(0xFFFFFF, 0), color(0xFFFFFF, 0.1)], atLocations: [0, 0.35, 1],
                   colorSpace: .sRGB)!.draw(in: screen, angle: -90)
        cg.restoreGState()
    }

    // 範囲選択のかぎ括弧（四隅）
    let sel = rect(236, 262, 352, 300)
    let arm = 92 * u
    cg.saveGState()
    cg.setStrokeColor(color(0xFBF6EC).cgColor)
    cg.setLineWidth(30 * u)
    cg.setLineCap(.round)
    cg.setLineJoin(.round)
    for (x, y, dx, dy) in [(sel.minX, sel.minY, arm, arm), (sel.maxX, sel.minY, -arm, arm),
                           (sel.minX, sel.maxY, arm, -arm), (sel.maxX, sel.maxY, -arm, -arm)] {
        cg.move(to: CGPoint(x: x, y: y + dy))
        cg.addLine(to: CGPoint(x: x, y: y))
        cg.addLine(to: CGPoint(x: x + dx, y: y))
    }
    cg.strokePath()
    cg.restoreGState()

    // 録画の点（選択範囲の中央）
    cg.setFillColor(color(0xCF6A70).cgColor)
    cg.fillEllipse(in: rect(412 - 44, 412 - 44, 88, 88))

    if dev {
        let band = CGRect(x: 0, y: 0, width: s, height: s * 0.19)
        color(0xFF8A00).setFill()
        NSBezierPath(rect: band).fill()
        let font = NSFont.systemFont(ofSize: s * 0.12, weight: .heavy)
        let str = NSAttributedString(string: "DEV", attributes: [.font: font, .foregroundColor: NSColor.white, .kern: s * 0.012])
        let line = CTLineCreateWithAttributedString(str)
        let b = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        str.draw(at: CGPoint(x: band.midX - b.midX, y: band.midY - b.midY))
    }
    NSGraphicsContext.restoreGraphicsState()
    return NSBitmapImageRep(cgImage: cg.makeImage()!)
}

try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
for px in [16, 32, 64, 128, 256, 512, 1024] {
    let png = render(px).representation(using: .png, properties: [:])!
    try! png.write(to: URL(fileURLWithPath: "\(outDir)/icon_\(px).png"))
}
let contents = """
{
  "images" : [
    { "filename" : "icon_16.png",   "idiom" : "mac", "scale" : "1x", "size" : "16x16" },
    { "filename" : "icon_32.png",   "idiom" : "mac", "scale" : "2x", "size" : "16x16" },
    { "filename" : "icon_32.png",   "idiom" : "mac", "scale" : "1x", "size" : "32x32" },
    { "filename" : "icon_64.png",   "idiom" : "mac", "scale" : "2x", "size" : "32x32" },
    { "filename" : "icon_128.png",  "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
    { "filename" : "icon_256.png",  "idiom" : "mac", "scale" : "2x", "size" : "128x128" },
    { "filename" : "icon_256.png",  "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
    { "filename" : "icon_512.png",  "idiom" : "mac", "scale" : "2x", "size" : "256x256" },
    { "filename" : "icon_512.png",  "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
    { "filename" : "icon_1024.png", "idiom" : "mac", "scale" : "2x", "size" : "512x512" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}

"""
try! contents.write(toFile: "\(outDir)/Contents.json", atomically: true, encoding: .utf8)
print("OK: \(outDir)")
