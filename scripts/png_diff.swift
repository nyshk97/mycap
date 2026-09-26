// 2 枚の PNG を sRGB の RGBA に描いて、大きさと画素の差の最大値を出す（スクロールキャプチャの検証: scripts/make_scroll_fixture.py）
// 使い方: swift scripts/png_diff.swift a.png b.png  →  a=WxH b=WxH maxdiff=N
import AppKit
func px(_ p: String) -> (Int, Int, [UInt8]) {
    let img = NSImage(contentsOfFile: p)!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    var d = [UInt8](repeating: 0, count: img.width * img.height * 4)
    let ctx = CGContext(data: &d, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
    return (img.width, img.height, d)
}
let a = px(CommandLine.arguments[1]), b = px(CommandLine.arguments[2])
var maxd = 0
if a.0 == b.0 && a.1 == b.1 { for i in 0..<a.2.count { maxd = max(maxd, abs(Int(a.2[i]) - Int(b.2[i]))) } }
print("a=\(a.0)x\(a.1) b=\(b.0)x\(b.1) maxdiff=\(maxd)")
