import CoreGraphics
import CoreText
import Foundation

/// 注釈の描画（純粋関数）。保存の焼き込みと編集画面の表示の両方がこれで描くので、見た目と出力が一致する。
/// 描く先の `CGContext` は「画像のピクセル・左上原点」の座標系にしてから渡す（`render` がその例）
enum AnnotationRenderer {
    /// 元画像に注釈を焼き込んだ画像。重ね順は描いた順（配列の順）
    static func render(_ image: CGImage, annotations: [Annotation]) -> CGImage? {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // 左上原点に揃える
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        drawImage(image, in: CGRect(x: 0, y: 0, width: w, height: h), ctx: ctx)
        for a in annotations {
            draw(a, in: ctx, mosaic: a.kind == .mosaic ? pixelated(image, rect: a.rect, block: a.size) : nil)
        }
        return ctx.makeImage()
    }

    /// 左上原点の座標系で画像を正立させて描く
    static func drawImage(_ image: CGImage, in rect: CGRect, ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(origin: .zero, size: rect.size))
        ctx.restoreGState()
    }

    /// 1 つ描く。モザイクは `pixelated` で作った画像を渡す（編集画面ではキャッシュしたものを渡す）
    static func draw(_ a: Annotation, in ctx: CGContext, mosaic: CGImage?) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        switch a.kind {
        case .mosaic:
            guard let mosaic else { return }
            ctx.interpolationQuality = .none
            // `pixelated` は画像の外にはみ出た分を削っているので、左上だけ画像の内側に寄せる
            let r = a.rect.integral
            drawImage(mosaic, in: CGRect(x: max(0, r.minX), y: max(0, r.minY), width: CGFloat(mosaic.width), height: CGFloat(mosaic.height)), ctx: ctx)
        case .arrow:
            setShadow(ctx, size: a.size)
            ctx.addPath(arrowPath(from: a.start, to: a.end, width: a.size))
            ctx.setFillColor(a.color.cgColor)
            ctx.fillPath()
        case .rect:
            setShadow(ctx, size: a.size)
            ctx.setStrokeColor(a.color.cgColor)
            ctx.setLineWidth(a.size)
            ctx.setLineJoin(.round)
            ctx.stroke(a.rect)
        case .text:
            setShadow(ctx, size: a.size / 6)
            let font = a.font.ctFont(size: a.size)
            let attrs: [CFString: Any] = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: a.color.cgColor]
            var y = a.start.y
            for line in lines(a.text) {
                let ct = CTLineCreateWithAttributedString(NSAttributedString(string: line, attributes: attrs as [NSAttributedString.Key: Any]))
                y += CTFontGetAscent(font)
                ctx.saveGState()
                // 左上原点の座標系では文字が逆さになるので、行ごとに戻す
                ctx.textMatrix = .identity
                ctx.translateBy(x: a.start.x, y: y)
                ctx.scaleBy(x: 1, y: -1)
                ctx.textPosition = .zero
                CTLineDraw(ct, ctx)
                ctx.restoreGState()
                y += CTFontGetDescent(font) + CTFontGetLeading(font)
            }
        }
    }

    /// 柔らかい影（下向き）。影はデバイス空間で効くので、表示の倍率を掛けて見た目の大きさを揃える
    private static func setShadow(_ ctx: CGContext, size: Double) {
        let k = abs(ctx.userSpaceToDeviceSpaceTransform.a)
        let blur = max(2, size * 1.5) * k
        ctx.setShadow(offset: CGSize(width: 0, height: -max(1, size * 0.3) * k), blur: blur,
                      color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.35))
    }

    /// 元画像の `rect` をピクセル化した画像（大きさは `rect` と同じ。ブロックの一辺は `block` ピクセル）。
    /// 常に元画像から取るので、下に描いた注釈を巻き込まない
    static func pixelated(_ image: CGImage, rect: CGRect, block: Double) -> CGImage? {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let r = rect.integral.intersection(bounds)
        guard r.width >= 1, r.height >= 1, let crop = image.cropping(to: r) else { return nil }
        let b = max(1, block)
        let cols = max(1, Int((r.width / b).rounded(.up))), rows = max(1, Int((r.height / b).rounded(.up)))
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        // 縮小（平均）→ 最近傍で拡大
        guard let small = CGContext(data: nil, width: cols, height: rows, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: info)
        else { return nil }
        small.interpolationQuality = .medium
        small.draw(crop, in: CGRect(x: 0, y: 0, width: cols, height: rows))
        guard let tiny = small.makeImage(),
              let big = CGContext(data: nil, width: Int(r.width), height: Int(r.height), bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: info)
        else { return nil }
        big.interpolationQuality = .none
        big.draw(tiny, in: CGRect(x: 0, y: 0, width: r.width, height: r.height))
        return big.makeImage()
    }

    // MARK: - 形

    /// CleanShot 風の矢印の外形。始点が細く終点へ向かって太くなる軸と、塗りつぶしの三角の頭。
    /// `width` は頭の付け根の軸の太さ。短い矢印では頭を縮める
    static func arrowPoints(from p: CGPoint, to q: CGPoint, width w: Double) -> [CGPoint] {
        let dx = q.x - p.x, dy = q.y - p.y
        let length = max(hypot(dx, dy), 0.001)
        let ux = dx / length, uy = dy / length   // 進む向き
        let nx = -uy, ny = ux                    // 横向き
        let headLength = min(w * 4.5, length * 0.6)
        let headWidth = headLength / 4.5 * 3.6
        let neck = min(w, headWidth * 0.5)
        let tail = neck * 0.35
        let barbBack = headLength * 1.1
        func at(_ along: Double, _ side: Double) -> CGPoint {
            CGPoint(x: p.x + ux * along + nx * side, y: p.y + uy * along + ny * side)
        }
        return [
            at(0, -tail / 2),
            at(length - headLength, -neck / 2),
            at(length - barbBack, -headWidth / 2),
            q,
            at(length - barbBack, headWidth / 2),
            at(length - headLength, neck / 2),
            at(0, tail / 2),
        ]
    }

    static func arrowPath(from p: CGPoint, to q: CGPoint, width: Double) -> CGPath {
        let path = CGMutablePath()
        path.addLines(between: arrowPoints(from: p, to: q, width: width))
        path.closeSubpath()
        return path
    }

    /// 文字の行（末尾の改行でも空行を 1 つ持つ。入力中のカーソル位置を含めて大きさを測るため）
    static func lines(_ text: String) -> [String] {
        text.components(separatedBy: "\n")
    }

    /// 文字の外接の大きさ（ピクセル）。空なら 1 文字分の高さと最小の幅
    static func textSize(_ a: Annotation) -> CGSize {
        let font = a.font.ctFont(size: a.size)
        let lineHeight = CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)
        let attrs = [NSAttributedString.Key(kCTFontAttributeName as String): font]
        var width: CGFloat = 0
        let all = lines(a.text)
        for line in all {
            let ct = CTLineCreateWithAttributedString(NSAttributedString(string: line, attributes: attrs))
            width = max(width, CTLineGetTypographicBounds(ct, nil, nil, nil))
        }
        return CGSize(width: max(width, a.size * 0.5), height: lineHeight * CGFloat(all.count))
    }
}
