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

    func testNewestIsBottomRightAndOlderStackUp() {
        let sizes = [CGSize(width: 240, height: 135), CGSize(width: 150, height: 150)]
        let frames = ThumbnailLayout.frames(visible: builtIn, sizes: sizes)
        XCTAssertEqual(frames[0].maxX, builtIn.maxX - ThumbnailLayout.margin)
        XCTAssertEqual(frames[0].minY, builtIn.minY + ThumbnailLayout.margin)
        XCTAssertEqual(frames[1].minY, frames[0].maxY + ThumbnailLayout.spacing)
        XCTAssertEqual(frames[1].maxX, builtIn.maxX - ThumbnailLayout.margin)
    }

    func testFramesStayOnSecondaryDisplayWithNegativeOrigin() {
        let frames = ThumbnailLayout.frames(visible: studioLeft, sizes: [ThumbnailLayout.maxBox, ThumbnailLayout.maxBox])
        for f in frames {
            XCTAssertTrue(studioLeft.contains(f), "\(f) が \(studioLeft) からはみ出す")
        }
        XCTAssertEqual(frames[0].maxX, -ThumbnailLayout.margin)
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
