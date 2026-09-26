import XCTest

/// 画素を読むための小道具（(x, y) は左上原点。RGBA premultiplied）
private enum Pix {
    static let space = CGColorSpace(name: CGColorSpace.sRGB)!
    static let info = CGImageAlphaInfo.premultipliedLast.rawValue

    static func image(_ w: Int, _ h: Int, fill: (CGContext) -> Void) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: info)!
        fill(ctx)
        return ctx.makeImage()!
    }

    static func white(_ w: Int, _ h: Int) -> CGImage {
        image(w, h) { $0.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)); $0.fill(CGRect(x: 0, y: 0, width: w, height: h)) }
    }

    /// 1px 幅の白黒の縦縞
    static func stripes(_ w: Int, _ h: Int) -> CGImage {
        image(w, h) { ctx in
            ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
            for x in stride(from: 0, to: w, by: 2) { ctx.fill(CGRect(x: x, y: 0, width: 1, height: h)) }
        }
    }

    static func at(_ image: CGImage, _ x: Int, _ y: Int) -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &buf, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space, bitmapInfo: info)!
        ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return buf
    }

    static func isRed(_ p: [UInt8]) -> Bool { p[0] > 200 && p[1] < 110 && p[2] < 110 }
}

final class AnnotationRendererTests: XCTestCase {
    func testRectStrokeIsColoredAndInsideKeepsImage() {
        let a = Annotation(kind: .rect, start: CGPoint(x: 20, y: 10), end: CGPoint(x: 80, y: 40), size: 4)
        let out = AnnotationRenderer.render(Pix.white(100, 60), annotations: [a])!
        XCTAssertEqual(out.width, 100)
        XCTAssertEqual(out.height, 60)
        // 上辺（y=10。左上原点なので上の方）と左辺が赤
        XCTAssertTrue(Pix.isRed(Pix.at(out, 50, 10)), "\(Pix.at(out, 50, 10))")
        XCTAssertTrue(Pix.isRed(Pix.at(out, 20, 25)), "\(Pix.at(out, 20, 25))")
        // 中と、上下を取り違えた位置（y=50）は白のまま
        XCTAssertEqual(Pix.at(out, 50, 25), [255, 255, 255, 255])
        XCTAssertFalse(Pix.isRed(Pix.at(out, 50, 50)))
    }

    func testMosaicIsBlockyInsideAndUntouchedOutside() {
        let a = Annotation(kind: .mosaic, start: CGPoint(x: 10, y: 10), end: CGPoint(x: 50, y: 50), size: 10)
        let src = Pix.stripes(60, 60)
        let out = AnnotationRenderer.render(src, annotations: [a])!
        // 中は縞が平均されて灰色、ブロック（10px）の中は一様
        let p = Pix.at(out, 12, 12)
        XCTAssertTrue((60...200).contains(Int(p[0])), "\(p)")
        for (x, y) in [(13, 12), (19, 19), (10, 15)] {
            XCTAssertEqual(Pix.at(out, x, y), p, "(\(x),\(y))")
        }
        // 外は縞のまま
        XCTAssertEqual(Pix.at(out, 4, 30), Pix.at(src, 4, 30))
        XCTAssertEqual(Pix.at(out, 5, 30), Pix.at(src, 5, 30))
        XCTAssertNotEqual(Pix.at(out, 4, 30), Pix.at(out, 5, 30))
    }

    func testMosaicTakesPixelsFromOriginalNotFromAnnotationsBelow() {
        let rect = Annotation(kind: .rect, start: CGPoint(x: 10, y: 10), end: CGPoint(x: 50, y: 50), size: 6)
        let mosaic = Annotation(kind: .mosaic, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 60, y: 60), size: 8)
        let out = AnnotationRenderer.render(Pix.white(60, 60), annotations: [rect, mosaic])!
        XCTAssertEqual(Pix.at(out, 10, 30), [255, 255, 255, 255])
    }

    func testMosaicOverflowingImageIsClipped() {
        let a = Annotation(kind: .mosaic, start: CGPoint(x: 40, y: 40), end: CGPoint(x: 90, y: 90), size: 8)
        let out = AnnotationRenderer.render(Pix.stripes(60, 60), annotations: [a])!
        let p = Pix.at(out, 41, 41)
        XCTAssertTrue((60...200).contains(Int(p[0])), "\(p)")
        XCTAssertEqual(Pix.at(out, 59, 59)[3], 255)
    }

    func testArrowIsColoredNearTipAndAlongShaft() {
        let a = Annotation(kind: .arrow, start: CGPoint(x: 10, y: 50), end: CGPoint(x: 150, y: 50), color: AnnotationColor.presets[4], size: 6)
        let out = AnnotationRenderer.render(Pix.white(200, 100), annotations: [a])!
        func isBlue(_ p: [UInt8]) -> Bool { p[2] > 200 && p[0] < 80 }
        XCTAssertTrue(isBlue(Pix.at(out, 145, 50)), "\(Pix.at(out, 145, 50))")    // 頭
        XCTAssertTrue(isBlue(Pix.at(out, 125, 56)), "\(Pix.at(out, 125, 56))")    // 頭の返し（軸の太さ 6 の外）
        XCTAssertTrue(isBlue(Pix.at(out, 80, 50)), "\(Pix.at(out, 80, 50))")      // 軸
        XCTAssertFalse(isBlue(Pix.at(out, 170, 50)))                               // 先端より先
        XCTAssertFalse(isBlue(Pix.at(out, 80, 20)))
    }

    func testTextIsDrawnInsideItsBounds() {
        let a = Annotation(kind: .text, start: CGPoint(x: 20, y: 10), end: .zero, size: 40, text: "■■\n■")
        let out = AnnotationRenderer.render(Pix.white(300, 160), annotations: [a])!
        let b = AnnotationGeometry.bounds(a)
        XCTAssertGreaterThan(b.height, 80) // 2 行
        var inside = 0, outside = 0
        for y in stride(from: 0, to: 160, by: 2) {
            for x in stride(from: 0, to: 300, by: 2) where Pix.isRed(Pix.at(out, x, y)) {
                if b.insetBy(dx: -2, dy: -2).contains(CGPoint(x: x, y: y)) { inside += 1 } else { outside += 1 }
            }
        }
        XCTAssertGreaterThan(inside, 100)
        XCTAssertEqual(outside, 0)
        // 1 行目は 2 文字・2 行目は 1 文字なので、右下は空いている（上下が逆さなら 1 行目の位置に 1 文字が来る）
        XCTAssertTrue(Pix.isRed(Pix.at(out, Int(b.maxX) - 10, Int(b.minY + b.height * 0.25))))
        XCTAssertFalse(Pix.isRed(Pix.at(out, Int(b.maxX) - 10, Int(b.minY + b.height * 0.75))))
    }

    func testEmptyAnnotationsKeepImage() {
        let out = AnnotationRenderer.render(Pix.stripes(20, 10), annotations: [])!
        XCTAssertEqual(Pix.at(out, 0, 0), Pix.at(Pix.stripes(20, 10), 0, 0))
        XCTAssertEqual(Pix.at(out, 1, 0), Pix.at(Pix.stripes(20, 10), 1, 0))
    }

    func testArrowHeadShrinksForShortArrows() {
        let pts = AnnotationRenderer.arrowPoints(from: .zero, to: CGPoint(x: 10, y: 0), width: 8)
        // 頭の返しが始点より後ろに行かない
        XCTAssertTrue(pts.allSatisfy { $0.x >= -0.01 }, "\(pts)")
    }
}

final class AnnotationGeometryTests: XCTestCase {
    private let rect = Annotation(kind: .rect, start: CGPoint(x: 100, y: 100), end: CGPoint(x: 10, y: 20), size: 4)

    func testRectIsNormalized() {
        XCTAssertEqual(rect.rect, CGRect(x: 10, y: 20, width: 90, height: 80))
    }

    func testRectHitsOnlyNearBorder() {
        XCTAssertNotNil(AnnotationGeometry.hit([rect], at: CGPoint(x: 10, y: 60), tolerance: 4))
        XCTAssertNotNil(AnnotationGeometry.hit([rect], at: CGPoint(x: 55, y: 103), tolerance: 4))
        XCTAssertNil(AnnotationGeometry.hit([rect], at: CGPoint(x: 55, y: 60), tolerance: 4))
        XCTAssertNil(AnnotationGeometry.hit([rect], at: CGPoint(x: 150, y: 60), tolerance: 4))
    }

    func testHitPrefersTopmost() {
        let mosaic = Annotation(kind: .mosaic, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 200, y: 200), size: 10)
        XCTAssertEqual(AnnotationGeometry.hit([rect, mosaic], at: CGPoint(x: 10, y: 60), tolerance: 4), 1)
        XCTAssertEqual(AnnotationGeometry.hit([mosaic, rect], at: CGPoint(x: 10, y: 60), tolerance: 4), 1)
        XCTAssertEqual(AnnotationGeometry.hit([mosaic, rect], at: CGPoint(x: 55, y: 60), tolerance: 4), 0)
    }

    func testArrowHitsNearSegment() {
        let a = Annotation(kind: .arrow, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 100, y: 100), size: 4)
        XCTAssertNotNil(AnnotationGeometry.hit([a], at: CGPoint(x: 52, y: 48), tolerance: 4))
        XCTAssertNil(AnnotationGeometry.hit([a], at: CGPoint(x: 80, y: 20), tolerance: 4))
        XCTAssertNil(AnnotationGeometry.hit([a], at: CGPoint(x: 130, y: 130), tolerance: 4))
    }

    func testResizeByHandles() {
        let r = AnnotationGeometry.resized(rect, handle: .bottomRight, to: CGPoint(x: 150, y: 120))
        XCTAssertEqual(r.rect, CGRect(x: 10, y: 20, width: 140, height: 100))
        let t = AnnotationGeometry.resized(rect, handle: .top, to: CGPoint(x: 999, y: 0))
        XCTAssertEqual(t.rect, CGRect(x: 10, y: 0, width: 90, height: 100))
        // 反対側を越えたら裏返る
        let f = AnnotationGeometry.resized(rect, handle: .left, to: CGPoint(x: 130, y: 0))
        XCTAssertEqual(f.rect, CGRect(x: 100, y: 20, width: 30, height: 80))
        let a = Annotation(kind: .arrow, start: .zero, end: CGPoint(x: 10, y: 10), size: 4)
        XCTAssertEqual(AnnotationGeometry.resized(a, handle: .end, to: CGPoint(x: 5, y: 50)).end, CGPoint(x: 5, y: 50))
        XCTAssertEqual(AnnotationGeometry.handle(of: a, at: CGPoint(x: 11, y: 9), tolerance: 4), .end)
        XCTAssertEqual(AnnotationGeometry.handles(rect).count, 8)
    }

    func testMove() {
        let m = AnnotationGeometry.moved(rect, by: CGSize(width: 5, height: -5))
        XCTAssertEqual(m.rect, CGRect(x: 15, y: 15, width: 90, height: 80))
    }

    func testConstrained() {
        XCTAssertEqual(AnnotationGeometry.constrained(.rect, from: .zero, to: CGPoint(x: -30, y: 10)), CGPoint(x: -30, y: 30))
        let e = AnnotationGeometry.constrained(.arrow, from: .zero, to: CGPoint(x: 100, y: 8))
        XCTAssertEqual(e.y, 0, accuracy: 0.001)
        XCTAssertEqual(e.x, hypot(100, 8), accuracy: 0.001)
    }

    func testMeaningful() {
        XCTAssertFalse(AnnotationGeometry.isMeaningful(Annotation(kind: .rect, start: .zero, end: CGPoint(x: 1, y: 50), size: 4)))
        XCTAssertTrue(AnnotationGeometry.isMeaningful(rect))
        XCTAssertFalse(AnnotationGeometry.isMeaningful(Annotation(kind: .text, start: .zero, end: .zero, size: 20, text: " \n")))
    }
}

final class AnnotationModelTests: XCTestCase {
    func testUndoRedo() {
        var h = AnnotationHistory()
        let a = Annotation(kind: .rect, start: .zero, end: CGPoint(x: 10, y: 10), size: 4)
        var current: [Annotation] = []
        h.record(current); current = [a]
        var b = a; b.color = .presets[4]
        h.record(current); current = [b]
        current = h.undo(current)!
        XCTAssertEqual(current, [a])
        current = h.undo(current)!
        XCTAssertEqual(current, [])
        XCTAssertNil(h.undo(current))
        current = h.redo(current)!
        XCTAssertEqual(current, [a])
        // 新しい変更でやり直しは消える
        h.record(current); current = []
        XCTAssertNil(h.redo(current))
    }

    func testCodableRoundTripAndMinimalJSON() throws {
        let a = Annotation(kind: .text, start: CGPoint(x: 1, y: 2), end: .zero, color: .presets[3], size: 24, text: "日本語", font: .mincho)
        XCTAssertEqual(try JSONDecoder().decode(Annotation.self, from: JSONEncoder().encode(a)), a)
        let json = #"[{"kind":"rect","start":[10,20],"end":[30,40],"size":4},{"kind":"text","start":[5,5],"size":20,"text":"x"}]"#
        let list = try JSONDecoder().decode([Annotation].self, from: Data(json.utf8))
        XCTAssertEqual(list[0].rect, CGRect(x: 10, y: 20, width: 20, height: 20))
        XCTAssertEqual(list[0].color, .red)
        XCTAssertEqual(list[1].font, .gothicBold)
    }
}
