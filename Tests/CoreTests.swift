import XCTest

final class FileNamingTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!

    func testStemIsZeroPaddedAndAsciiOnly() {
        // 2026-01-02 03:04:05 UTC
        let date = Date(timeIntervalSince1970: 1_767_323_045)
        XCTAssertEqual(FileNaming.stem(for: date, timeZone: utc), "2026-01-02_03-04-05")
    }

    func testStemIgnoresJapaneseLocaleAndCalendar() {
        // 端末の地域設定が和暦・12 時間制でも西暦 24 時間制で出る（DateFormatter を en_US_POSIX に固定している）
        let date = Date(timeIntervalSince1970: 1_767_366_245) // 2026-01-02 15:04:05 UTC
        XCTAssertEqual(FileNaming.stem(for: date, timeZone: utc), "2026-01-02_15-04-05")
    }

    func testDateFromNameRoundTrips() {
        let date = Date(timeIntervalSince1970: 1_767_366_245)
        let stem = FileNaming.stem(for: date, timeZone: utc)
        XCTAssertEqual(FileNaming.date(fromName: stem + ".png", timeZone: utc), date)
        XCTAssertEqual(FileNaming.date(fromName: stem + "_3.mp4", timeZone: utc), date)
    }

    func testDateFromNameRejectsOtherNames() {
        XCTAssertNil(FileNaming.date(fromName: "2026-01-02_15-04-05_styled.png", timeZone: utc))
        XCTAssertNil(FileNaming.date(fromName: "2026-01-02_15-04-05", timeZone: utc))
        XCTAssertNil(FileNaming.date(fromName: "x2026-01-02_15-04-05.png", timeZone: utc))
        XCTAssertNil(FileNaming.date(fromName: ".DS_Store", timeZone: utc))
        XCTAssertNil(FileNaming.date(fromName: "2026-13-02_15-04-05.png", timeZone: utc))
    }

    func testUniqueNameReturnsPlainNameWhenFree() {
        XCTAssertEqual(FileNaming.uniqueName(stem: "a", ext: "png") { _ in false }, "a.png")
    }

    func testUniqueNameAddsSuffixFromTwo() {
        let taken: Set<String> = ["a.png", "a_2.png", "a_3.png"]
        XCTAssertEqual(FileNaming.uniqueName(stem: "a", ext: "png") { taken.contains($0) }, "a_4.png")
    }

    func testUniqueNameIsPerExtension() {
        // 同じ秒の png があっても mp4 は素の名前を使える
        let taken: Set<String> = ["a.png"]
        XCTAssertEqual(FileNaming.uniqueName(stem: "a", ext: "mp4") { taken.contains($0) }, "a.mp4")
    }
}

final class ThumbnailLayoutTests: XCTestCase {
    /// 内蔵 15"（1512×982pt）でメニューバー（ノッチ付き 37pt）と Dock（70pt）を引いた、いちばん狭い visibleFrame
    private let builtIn = CGRect(x: 0, y: 70, width: 1512, height: 982 - 37 - 70)
    /// Studio Display（2560×1440pt）を内蔵の左に置いた場合。x が負になる
    private let studioLeft = CGRect(x: -2560, y: 0, width: 2560, height: 1440 - 25)

    func testPanelSizeFitsInBoxKeepingAspect() {
        // 2x で撮った 1920×1080px = 960×540pt → 箱の幅 240 に合わせて 240×135
        XCTAssertEqual(ThumbnailLayout.panelSize(for: CGSize(width: 960, height: 540)), CGSize(width: 240, height: 135))
        // 縦長は高さ 150 に合わせる
        XCTAssertEqual(ThumbnailLayout.panelSize(for: CGSize(width: 300, height: 900)).height, 150)
    }

    func testPanelSizeDoesNotUpscaleButKeepsMinimum() {
        // 小さい画像は拡大しない。ボタンが並ぶ最小の大きさは確保する
        XCTAssertEqual(ThumbnailLayout.panelSize(for: CGSize(width: 40, height: 20)), ThumbnailLayout.minPanel)
        // 極端な横長も最小の高さを下回らない
        XCTAssertEqual(ThumbnailLayout.panelSize(for: CGSize(width: 3000, height: 50)).height, ThumbnailLayout.minPanel.height)
    }

    func testFiveTallestFitOnBuiltInDisplay() {
        let sizes = Array(repeating: ThumbnailLayout.maxBox, count: ThumbnailLayout.maxCount)
        let frames = ThumbnailLayout.frames(visible: builtIn, sizes: sizes)
        XCTAssertEqual(frames.count, 5)
        for f in frames {
            XCTAssertTrue(builtIn.contains(f), "\(f) が \(builtIn) からはみ出す")
        }
        // 実測: 最上段の上端（はみ出さないことの余裕を出しておく）
        let top = frames.map(\.maxY).max()!
        XCTAssertLessThanOrEqual(top, builtIn.maxY, "top=\(top) visibleMaxY=\(builtIn.maxY)")
    }

    func testNewestIsBottomLeftAndOlderStackUp() {
        let sizes = [CGSize(width: 240, height: 135), CGSize(width: 150, height: 150)]
        let frames = ThumbnailLayout.frames(visible: builtIn, sizes: sizes)
        XCTAssertEqual(frames[0].minX, builtIn.minX + ThumbnailLayout.margin)
        XCTAssertEqual(frames[0].minY, builtIn.minY + ThumbnailLayout.margin)
        XCTAssertEqual(frames[1].minY, frames[0].maxY + ThumbnailLayout.spacing)
        XCTAssertEqual(frames[1].minX, builtIn.minX + ThumbnailLayout.margin)
    }

    func testFramesStayOnSecondaryDisplayWithNegativeOrigin() {
        let frames = ThumbnailLayout.frames(visible: studioLeft, sizes: [ThumbnailLayout.maxBox, ThumbnailLayout.maxBox])
        for f in frames {
            XCTAssertTrue(studioLeft.contains(f), "\(f) が \(studioLeft) からはみ出す")
        }
        XCTAssertEqual(frames[0].minX, -2560 + ThumbnailLayout.margin)
    }

    func testToastSitsRightOfThumbnailCenteredVertically() {
        let anchor = ThumbnailLayout.frames(visible: builtIn, sizes: [CGSize(width: 240, height: 135)])[0]
        let origin = ThumbnailLayout.toastOrigin(anchor: anchor, size: CGSize(width: 140, height: 40), visible: builtIn)
        XCTAssertEqual(origin.x, anchor.maxX + ThumbnailLayout.spacing)
        XCTAssertEqual(origin.y + 20, anchor.midY)
    }

    func testToastStaysInsideVisibleFrame() {
        // 最小のサムネイルより背の高い通知（折り返した OCR の結果）でも画面の下にはみ出さない
        let anchor = ThumbnailLayout.frames(visible: studioLeft, sizes: [ThumbnailLayout.minPanel])[0]
        let size = CGSize(width: 460, height: 200)
        let origin = ThumbnailLayout.toastOrigin(anchor: anchor, size: size, visible: studioLeft)
        XCTAssertTrue(studioLeft.contains(CGRect(origin: origin, size: size)), "origin=\(origin)")
        XCTAssertEqual(origin.y, studioLeft.minY, "anchor.midY=\(anchor.midY)")
        // 右端に寄ったサムネイルでも通知は画面の中に収まる
        let right = CGRect(x: builtIn.maxX - 100, y: 400, width: 90, height: 96)
        let o2 = ThumbnailLayout.toastOrigin(anchor: right, size: CGSize(width: 140, height: 40), visible: builtIn)
        XCTAssertEqual(o2.x, builtIn.maxX - 140)
    }

    func testOverflowKeepsFive() {
        XCTAssertEqual(ThumbnailLayout.overflow(count: 5), 0)
        XCTAssertEqual(ThumbnailLayout.overflow(count: 6), 1)
    }
}

final class OCRTextTests: XCTestCase {
    private typealias F = OCRText.Fragment

    func testLinesTopToBottomAndLeftToRight() {
        // Vision の正規化座標は原点が左下（y が大きいほど上）。入力の順番はばらばらにしておく
        let text = OCRText.assemble([
            F("2 行目", CGRect(x: 0.1, y: 0.40, width: 0.3, height: 0.1)),
            F("右", CGRect(x: 0.6, y: 0.71, width: 0.1, height: 0.08)),
            F("左", CGRect(x: 0.1, y: 0.70, width: 0.1, height: 0.1)),
        ])
        XCTAssertEqual(text, "左右\n2 行目")
    }

    func testSpaceOnlyBetweenAsciiWords() {
        XCTAssertEqual(OCRText.join(["Screen", "Recording"]), "Screen Recording")
        XCTAssertEqual(OCRText.join(["画面", "収録"]), "画面収録")
        XCTAssertEqual(OCRText.join(["macOS", "の設定"]), "macOSの設定")
    }

    func testSmallVerticalOverlapIsSeparateLine() {
        // 高さの半分未満しか重ならない断片は別の行
        let text = OCRText.assemble([
            F("上", CGRect(x: 0.1, y: 0.50, width: 0.1, height: 0.1)),
            F("下", CGRect(x: 0.1, y: 0.42, width: 0.1, height: 0.1)),
        ])
        XCTAssertEqual(text, "上\n下")
    }

    func testEmptyInput() {
        XCTAssertEqual(OCRText.assemble([]), "")
        XCTAssertEqual(OCRText.assemble([F("  ", CGRect(x: 0, y: 0, width: 1, height: 1))]), "")
    }
}

final class PinLayoutTests: XCTestCase {
    private let builtIn = CGRect(x: 0, y: 77, width: 1512, height: 872)

    func testSmallImageIsActualSizeAndCentered() {
        let f = PinLayout.initialFrame(image: CGSize(width: 400, height: 300), visible: builtIn)
        XCTAssertEqual(f.size, CGSize(width: 400, height: 300))
        XCTAssertEqual(f.midX, builtIn.midX, accuracy: 1)
        XCTAssertEqual(f.midY, builtIn.midY, accuracy: 1)
    }

    func testLargeImageShrinksToFitScreen() {
        // Studio Display の全画面（2560×1440pt）を内蔵にピン留めする
        let f = PinLayout.initialFrame(image: CGSize(width: 2560, height: 1440), visible: builtIn)
        XCTAssertTrue(builtIn.contains(f), "\(f)")
        XCTAssertEqual(f.width / f.height, 2560 / 1440, accuracy: 0.01)
    }
}

final class StyleRendererTests: XCTestCase {
    /// 単色（赤）の画像を作る
    private func solid(_ w: Int, _ h: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()!
    }

    /// (x, y) は左上原点。RGBA（premultiplied）を返す
    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &buf, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return buf
    }

    func testOutputSizeAddsPaddingInPixels() {
        var s = StyleSettings()
        s.padding = 10
        // Retina（scale 2）の 100×50px に 10pt の余白 → 両側 20px ずつ
        XCTAssertEqual(StyleRenderer.outputSize(imagePixels: CGSize(width: 100, height: 50), scale: 2, settings: s),
                       CGSize(width: 140, height: 90))
    }

    func testPlainBackgroundAtCornerAndImageAtCenter() {
        var s = StyleSettings()
        s.background = .plain
        s.padding = 10
        s.shadow = false
        let out = StyleRenderer.render(solid(100, 50), scale: 2, settings: s)!
        XCTAssertEqual(out.width, 140)
        let corner = pixel(out, 0, 0)
        XCTAssertEqual(corner[3], 255)
        XCTAssertEqual(Int(corner[0]), 242, accuracy: 2) // 0.95 × 255
        let center = pixel(out, 70, 45)
        XCTAssertEqual(center, [255, 0, 0, 255])
    }

    func testTransparentBackgroundKeepsAlphaZeroAndRoundsCorners() {
        var s = StyleSettings()
        s.background = .transparent
        s.padding = 0
        s.cornerRadius = 10
        s.shadow = false
        let out = StyleRenderer.render(solid(100, 50), scale: 2, settings: s)!
        // 余白 0 なので画像の角 = 出力の角。角丸（20px）で削れて透明
        XCTAssertEqual(pixel(out, 0, 0)[3], 0)
        // 角から離れた縁の中央は画像のまま
        XCTAssertEqual(pixel(out, 50, 0), [255, 0, 0, 255])
    }

    func testGradientDiffersBetweenCorners() {
        var s = StyleSettings()
        s.background = .ocean
        s.padding = 20
        s.shadow = false
        let out = StyleRenderer.render(solid(40, 40), scale: 1, settings: s)!
        XCTAssertNotEqual(pixel(out, 0, 0), pixel(out, out.width - 1, out.height - 1))
    }

    func testSettingsRoundTripThroughJSON() throws {
        var s = StyleSettings()
        s.background = .dusk
        s.padding = 80
        let decoded = try JSONDecoder().decode(StyleSettings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(decoded, s)
    }
}

final class RecordingFormatTests: XCTestCase {
    func testLogicalResolutionForDisplays() {
        // Studio Display・内蔵 15" の論理解像度はそのまま（偶数）
        XCTAssertTrue(RecordingFormat.outputSize(points: CGSize(width: 2560, height: 1440)) == (2560, 1440))
        XCTAssertTrue(RecordingFormat.outputSize(points: CGSize(width: 1512, height: 982)) == (1512, 982))
    }

    func testOddWindowSizeRoundsDownToEven() {
        XCTAssertTrue(RecordingFormat.outputSize(points: CGSize(width: 801, height: 603.5)) == (800, 602))
    }

    func testTooWideShrinksWithinH264Limit() {
        let s = RecordingFormat.outputSize(points: CGSize(width: 6000, height: 1000))
        XCTAssertLessThanOrEqual(s.width, 4096)
        XCTAssertEqual(Double(s.width) / Double(s.height), 6.0, accuracy: 0.02)
    }

    func testElapsed() {
        XCTAssertEqual(RecordingFormat.elapsed(7), "0:07")
        XCTAssertEqual(RecordingFormat.elapsed(754), "12:34")
        XCTAssertEqual(RecordingFormat.elapsed(3723), "1:02:03")
    }
}

final class CacheRetentionTests: XCTestCase {
    func testMaxAgeIsSevenDays() {
        XCTAssertEqual(CacheRetention.maxAge, 7 * 86400)
    }

    func testOnlyOlderThanMaxAgeExpire() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let files: [(name: String, modified: Date)] = [
            ("fresh.png", now.addingTimeInterval(-60)),
            ("just-under.png", now.addingTimeInterval(-CacheRetention.maxAge + 1)),
            ("old.png", now.addingTimeInterval(-CacheRetention.maxAge - 1)),
            ("older.mp4", now.addingTimeInterval(-3 * CacheRetention.maxAge)),
        ]
        XCTAssertEqual(CacheRetention.expired(files, now: now), ["old.png", "older.mp4"])
    }
}

final class RegionMemoryTests: XCTestCase {
    func testDragInAnyDirectionMatchesImage() {
        let a = CGPoint(x: 300, y: 500), b = CGPoint(x: 100, y: 400)
        let r = RegionMemory.rect(from: a, to: b, imagePixels: CGSize(width: 400, height: 200), scale: 2)
        XCTAssertEqual(r, CGRect(x: 100, y: 400, width: 200, height: 100))
    }

    func testRoundingWithinTolerance() {
        let r = RegionMemory.rect(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 100.5, y: 50.5),
                                  imagePixels: CGSize(width: 202, height: 100), scale: 2)
        XCTAssertNotNil(r)
    }

    func testWindowCaptureOrClickIsRejected() {
        // Space でウィンドウを撮った（クリックだけ・影つきで大きさが合わない）
        XCTAssertNil(RegionMemory.rect(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 10, y: 10),
                                       imagePixels: CGSize(width: 1600, height: 1000), scale: 2))
        XCTAssertNil(RegionMemory.rect(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 100, y: 100),
                                       imagePixels: CGSize(width: 1600, height: 1000), scale: 2))
    }

    func testLocalIsTopLeftOriginOnBuiltIn() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let l = RegionMemory.local(CGRect(x: 100, y: 800, width: 200, height: 100), in: screen)
        XCTAssertEqual(l, CGRect(x: 100, y: 82, width: 200, height: 100))
    }

    func testLocalOnSecondaryDisplayWithNegativeOrigin() {
        // 内蔵の左上に置いた Studio Display
        let screen = CGRect(x: -1048, y: 982, width: 2560, height: 1440)
        let l = RegionMemory.local(CGRect(x: -1000, y: 2300, width: 300, height: 100), in: screen)
        XCTAssertEqual(l, CGRect(x: 48, y: 22, width: 300, height: 100))
    }

    func testLocalRejectsRectAcrossDisplays() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        XCTAssertNil(RegionMemory.local(CGRect(x: 1400, y: 100, width: 300, height: 100), in: screen))
    }
}

final class CaptureHistoryTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testKindByExtension() {
        XCTAssertEqual(CaptureHistory.Kind.of(ext: "png"), .screenshots)
        XCTAssertEqual(CaptureHistory.Kind.of(ext: "PNG"), .screenshots)
        XCTAssertEqual(CaptureHistory.Kind.of(ext: "mp4"), .videos)
        XCTAssertNil(CaptureHistory.Kind.of(ext: "tmp"))
        XCTAssertNil(CaptureHistory.Kind.of(ext: ""))
    }

    func testItemsFilterByKindNewestFirst() {
        let files = [
            CaptureHistory.Entry(name: "a.png", created: t0),
            CaptureHistory.Entry(name: "b.mp4", created: t0.addingTimeInterval(10)),
            CaptureHistory.Entry(name: "c_styled.png", created: t0.addingTimeInterval(20)),
            CaptureHistory.Entry(name: ".DS_Store", created: t0.addingTimeInterval(30)),
            CaptureHistory.Entry(name: "d.png", created: t0.addingTimeInterval(5)),
        ]
        XCTAssertEqual(CaptureHistory.items(files, kind: .screenshots).map(\.name), ["c_styled.png", "d.png", "a.png"])
        XCTAssertEqual(CaptureHistory.items(files, kind: .videos).map(\.name), ["b.mp4"])
    }

    func testItemsSameTimeUsesNameDescending() {
        let files = [
            CaptureHistory.Entry(name: "x.png", created: t0),
            CaptureHistory.Entry(name: "x_2.png", created: t0),
        ]
        XCTAssertEqual(CaptureHistory.items(files, kind: .screenshots).map(\.name), ["x_2.png", "x.png"])
    }

    func testRelativeAge() {
        XCTAssertEqual(CaptureHistory.relativeAge(-5), "just now")
        XCTAssertEqual(CaptureHistory.relativeAge(59), "just now")
        XCTAssertEqual(CaptureHistory.relativeAge(60), "1 minute ago")
        XCTAssertEqual(CaptureHistory.relativeAge(23 * 60 + 59), "23 minutes ago")
        XCTAssertEqual(CaptureHistory.relativeAge(3600), "1 hour ago")
        XCTAssertEqual(CaptureHistory.relativeAge(11 * 3600 + 3599), "11 hours ago")
        XCTAssertEqual(CaptureHistory.relativeAge(86400), "1 day ago")
        XCTAssertEqual(CaptureHistory.relativeAge(6 * 86400 + 1), "6 days ago")
    }

    func testDurationLabel() {
        XCTAssertEqual(CaptureHistory.durationLabel(0.2), "0s")
        XCTAssertEqual(CaptureHistory.durationLabel(1.6), "2s")
        XCTAssertEqual(CaptureHistory.durationLabel(59.4), "59s")
        XCTAssertEqual(CaptureHistory.durationLabel(65), "1:05")
        XCTAssertEqual(CaptureHistory.durationLabel(3723), "1:02:03")
    }

    func testMoveFocusStopsAtEnds() {
        XCTAssertNil(CaptureHistory.moveFocus(nil, by: 1, count: 0))
        XCTAssertNil(CaptureHistory.moveFocus(2, by: 1, count: 0))
        XCTAssertEqual(CaptureHistory.moveFocus(nil, by: 1, count: 3), 0)
        XCTAssertEqual(CaptureHistory.moveFocus(0, by: -1, count: 3), 0)
        XCTAssertEqual(CaptureHistory.moveFocus(0, by: 1, count: 3), 1)
        XCTAssertEqual(CaptureHistory.moveFocus(2, by: 1, count: 3), 2)
        // タブ切替などで件数が減ったら末尾に寄せる
        XCTAssertEqual(CaptureHistory.moveFocus(5, by: 0, count: 3), 2)
    }
}
