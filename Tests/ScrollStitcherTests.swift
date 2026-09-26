import XCTest

final class ScrollStitcherTests: XCTestCase {
    private let w = 200
    private let h = 300

    /// 縦長の「ページ」。行・列ごとに値が変わるノイズなので、どの dy でも取り違えない
    private func page(height: Int, seed: UInt32 = 1) -> PixelBuffer {
        var buf = PixelBuffer(width: w, height: height)
        for y in 0..<height {
            for x in 0..<w {
                var v = UInt32(truncatingIfNeeded: x &* 73856093) ^ UInt32(truncatingIfNeeded: y &* 19349663) ^ (seed &* 83492791)
                v = (v ^ (v >> 13)) &* 1274126177
                let p = y * buf.bytesPerRow + x * 4
                buf.data[p] = UInt8(truncatingIfNeeded: v)
                buf.data[p + 1] = UInt8(truncatingIfNeeded: v >> 8)
                buf.data[p + 2] = UInt8(truncatingIfNeeded: v >> 16)
                buf.data[p + 3] = 255
            }
        }
        return buf
    }

    /// 窓（高さ h）: 上に `header`、下に `footer` を重ね、その間にページの `offset` からの行を出す。行の詰め物も付ける
    private func window(_ page: PixelBuffer, offset: Int, header: PixelBuffer? = nil, footer: PixelBuffer? = nil,
                        padding: Int = 16) -> PixelBuffer {
        let hh = header?.height ?? 0, fh = footer?.height ?? 0
        var parts: [(PixelBuffer, Range<Int>)] = []
        if let header { parts.append((header, 0..<hh)) }
        parts.append((page, offset..<(offset + h - hh - fh)))
        if let footer { parts.append((footer, 0..<fh)) }
        let packed = PixelBuffer.stacked(parts, width: w)
        // bytesPerRow に詰め物がある形にする（SCK のコマと同じ）
        let bpr = w * 4 + padding
        var data = [UInt8](repeating: 7, count: bpr * h)
        for y in 0..<h {
            data.replaceSubrange((y * bpr)..<(y * bpr + w * 4), with: packed.data[(y * w * 4)..<((y + 1) * w * 4)])
        }
        return PixelBuffer(width: w, height: h, bytesPerRow: bpr, data: data)
    }

    private func solid(_ rows: Int, _ value: UInt8) -> PixelBuffer {
        var b = PixelBuffer(width: w, height: rows)
        for i in stride(from: 0, to: b.data.count, by: 4) { b.data[i] = value; b.data[i + 1] = value &+ 40; b.data[i + 2] = value &+ 80; b.data[i + 3] = 255 }
        return b
    }

    func testStitchesScrolledWindowsBackToThePage() {
        let p = page(height: 3000)
        let s = ScrollStitcher()
        var kinds: [ScrollStitcher.Outcome.Kind] = []
        for o in [0, 37, 120, 121, 260, 400, 590] { kinds.append(s.add(window(p, offset: o)).kind) }
        XCTAssertEqual(kinds, [.first, .appended, .appended, .appended, .appended, .appended, .appended])
        let out = s.compose()!
        XCTAssertEqual(out.height, 590 + h)
        XCTAssertTrue(out.samePixels(as: p.rows(0..<(590 + h))))
    }

    func testReportsDy() {
        let p = page(height: 1000)
        let s = ScrollStitcher()
        _ = s.add(window(p, offset: 0))
        XCTAssertEqual(s.add(window(p, offset: 45)).dy, 45)
    }

    func testStickyHeaderAndFooterAppearOnce() {
        let p = page(height: 3000)
        let header = solid(40, 10), footer = solid(30, 200)
        let s = ScrollStitcher()
        for o in [0, 50, 170, 300] { XCTAssertTrue(s.add(window(p, offset: o, header: header, footer: footer)).accepted) }
        XCTAssertEqual(s.header, 40)
        XCTAssertEqual(s.footer, 30)
        let body = h - 40 - 30
        let expected = PixelBuffer.stacked([(header, 0..<40), (p, 0..<(300 + body)), (footer, 0..<30)], width: w)
        XCTAssertTrue(s.compose()!.samePixels(as: expected))
    }

    /// 最後のコマだけフッタの帯の中身が違う（ページの末尾がフッタの位置に出ている）→ 最後につないだコマのものが出る
    func testFooterComesFromLastStitchedFrame() {
        let p = page(height: 3000)
        let header = solid(40, 10), footer = solid(30, 200), end = solid(30, 90)
        let s = ScrollStitcher()
        _ = s.add(window(p, offset: 0, header: header, footer: footer))
        _ = s.add(window(p, offset: 80, header: header, footer: footer))
        XCTAssertTrue(s.add(window(p, offset: 200, header: header, footer: end)).accepted)
        let out = s.compose()!
        XCTAssertTrue(out.rows((out.height - 30)..<out.height).samePixels(as: end))
    }

    func testScrollingBackUpThenPastTheOldPositionDoesNotDuplicate() {
        let p = page(height: 3000)
        let s = ScrollStitcher()
        _ = s.add(window(p, offset: 0))
        _ = s.add(window(p, offset: 200))
        XCTAssertEqual(s.add(window(p, offset: 120)).kind, .upward)
        XCTAssertEqual(s.add(window(p, offset: 60)).kind, .upward)
        XCTAssertEqual(s.add(window(p, offset: 150)).kind, .upward)
        XCTAssertEqual(s.add(window(p, offset: 260)).kind, .appended)
        XCTAssertTrue(s.compose()!.samePixels(as: p.rows(0..<(260 + h))))
    }

    func testOverlayScrollbarOnTheRightIsIgnored() {
        let p = page(height: 3000)
        let s = ScrollStitcher(options: .init(ignoreRight: 32))
        for (i, o) in [0, 60, 140, 230].enumerated() {
            var f = window(p, offset: o)
            if i % 2 == 1 {
                for y in 0..<h { for x in (w - 12)..<w { let q = y * f.bytesPerRow + x * 4; f.data[q] = 128; f.data[q + 1] = 128; f.data[q + 2] = 128 } }
            }
            XCTAssertTrue(s.add(f).accepted, "frame \(i)")
        }
        XCTAssertTrue(s.compose()!.samePixels(as: p.rows(0..<(230 + h)), ignoringRight: 32))
    }

    func testSameFrameAgainIsDropped() {
        let p = page(height: 1000)
        let s = ScrollStitcher()
        _ = s.add(window(p, offset: 0))
        XCTAssertEqual(s.add(window(p, offset: 0)).kind, .same)
        _ = s.add(window(p, offset: 50))
        XCTAssertEqual(s.add(window(p, offset: 50)).kind, .same)
        XCTAssertEqual(s.height, 50 + h)
    }

    func testSingleFrameIsTheOutput() {
        let p = page(height: 1000)
        let f = window(p, offset: 10)
        let s = ScrollStitcher()
        XCTAssertEqual(s.add(f).kind, .first)
        XCTAssertTrue(s.compose()!.samePixels(as: f))
        XCTAssertEqual(s.header, nil)
    }

    func testTooFastScrollWithoutOverlapIsDroppedAndRecoversWhenScrolledBack() {
        let p = page(height: 3000)
        let s = ScrollStitcher()
        _ = s.add(window(p, offset: 0))
        XCTAssertFalse(s.add(window(p, offset: 1000)).accepted)
        XCTAssertEqual(s.add(window(p, offset: 200)).kind, .appended)
        XCTAssertTrue(s.compose()!.samePixels(as: p.rows(0..<(200 + h))))
    }

    /// 周期的な縞と、無地の重なりは dy を 1 つに決められないので捨てる
    func testPeriodicAndBlankContentIsAmbiguous() {
        var stripes = PixelBuffer(width: w, height: 2000)
        for y in 0..<2000 where (y / 10) % 2 == 0 {
            for x in 0..<w { let q = y * stripes.bytesPerRow + x * 4; stripes.data[q] = 255; stripes.data[q + 1] = 255; stripes.data[q + 2] = 255 }
        }
        let s = ScrollStitcher()
        _ = s.add(window(stripes, offset: 0))
        XCTAssertEqual(s.add(window(stripes, offset: 35)).kind, .ambiguous)

        let blank = PixelBuffer(width: w, height: 2000)
        let b = ScrollStitcher()
        _ = b.add(window(blank, offset: 0))
        XCTAssertFalse(b.add(window(blank, offset: 35)).accepted)
        XCTAssertEqual(b.frameCount, 1)
    }

    func testStopsAtTheHeightLimit() {
        let p = page(height: 3000)
        let s = ScrollStitcher(options: .init(maxHeight: 500))
        _ = s.add(window(p, offset: 0))
        XCTAssertEqual(s.add(window(p, offset: 150)).kind, .appended)
        let r = s.add(window(p, offset: 280))
        XCTAssertEqual(r.kind, .limit)
        XCTAssertEqual(s.height, 500)
        XCTAssertTrue(s.isFull)
        XCTAssertEqual(s.add(window(p, offset: 400)).kind, .full)
        XCTAssertTrue(s.compose()!.samePixels(as: p.rows(0..<500)))
    }

    func testDifferentSizeIsDropped() {
        let s = ScrollStitcher()
        _ = s.add(PixelBuffer(width: 100, height: 100))
        XCTAssertEqual(s.add(PixelBuffer(width: 100, height: 120)).kind, .size)
    }

    func testComposeTailIsTheBottomOfCompose() {
        let p = page(height: 3000)
        let s = ScrollStitcher()
        for o in [0, 90, 210] { _ = s.add(window(p, offset: o)) }
        let all = s.compose()!
        let tail = s.composeTail(rows: 250)!
        XCTAssertEqual(tail.height, 250)
        XCTAssertTrue(tail.samePixels(as: all.rows((all.height - 250)..<all.height)))
        XCTAssertEqual(s.composeTail(rows: 99999)!.height, all.height)
    }
}

final class ScrollLayoutTests: XCTestCase {
    private let bounds = CGRect(x: 0, y: 0, width: 1512, height: 982)

    func testPreviewGoesRightThenLeftThenInside() {
        let bar = CGRect(x: 0, y: 0, width: 10, height: 10)
        let r = ScrollLayout.previewFrame(selection: CGRect(x: 100, y: 200, width: 600, height: 500), bar: bar, bounds: bounds)
        XCTAssertEqual(r.placement, .right)
        XCTAssertEqual(r.frame, CGRect(x: 708, y: 200, width: 160, height: 500))

        let l = ScrollLayout.previewFrame(selection: CGRect(x: 800, y: 200, width: 700, height: 500), bar: bar, bounds: bounds)
        XCTAssertEqual(l.placement, .left)
        XCTAssertEqual(l.frame.maxX, 792)

        let i = ScrollLayout.previewFrame(selection: bounds, bar: bar, bounds: bounds)
        XCTAssertEqual(i.placement, .inside)
        XCTAssertLessThanOrEqual(i.frame.maxX, bounds.maxX)
        XCTAssertLessThanOrEqual(i.frame.maxY, bounds.maxY)
    }

    func testPreviewHeightIsCapped() {
        let r = ScrollLayout.previewFrame(selection: CGRect(x: 100, y: 50, width: 400, height: 900), bar: .zero, bounds: bounds, maxHeight: 640)
        XCTAssertEqual(r.frame.height, 640)
        XCTAssertEqual(r.frame.maxY, 950)
    }

    /// 画面いっぱいの範囲ではバーも内側の右下に入るので、プレビューはバーの上で止める
    func testPreviewDoesNotOverlapTheBar() {
        let s = bounds
        let barSize = CGSize(width: 220, height: 34)
        let (origin, placement) = AIOLayout.recordingBarOrigin(selection: s, bar: barSize, bounds: bounds)
        XCTAssertEqual(placement, .inside)
        let bar = CGRect(origin: origin, size: barSize)
        let r = ScrollLayout.previewFrame(selection: s, bar: bar, bounds: bounds)
        XCTAssertFalse(r.frame.intersects(bar))
        XCTAssertGreaterThan(r.frame.height, 100)
    }
}
