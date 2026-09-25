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
