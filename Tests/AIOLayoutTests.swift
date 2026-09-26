import XCTest

final class AIOLayoutTests: XCTestCase {
    private let bounds = CGRect(x: 0, y: 0, width: 1512, height: 982)

    func testRectNormalizesAnyDragDirection() {
        let r = CGRect(x: 100, y: 200, width: 300, height: 150)
        XCTAssertEqual(AIOLayout.rect(from: CGPoint(x: 100, y: 200), to: CGPoint(x: 400, y: 350), in: bounds), r)
        XCTAssertEqual(AIOLayout.rect(from: CGPoint(x: 400, y: 350), to: CGPoint(x: 100, y: 200), in: bounds), r)
        XCTAssertEqual(AIOLayout.rect(from: CGPoint(x: 400, y: 200), to: CGPoint(x: 100, y: 350), in: bounds), r)
    }

    func testRectClampsToDisplay() {
        let r = AIOLayout.rect(from: CGPoint(x: -50, y: -20), to: CGPoint(x: 2000, y: 1200), in: bounds)
        XCTAssertEqual(r, bounds)
    }

    func testRectIgnoresClickAndTinyDrag() {
        XCTAssertNil(AIOLayout.rect(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 10, y: 10), in: bounds))
        XCTAssertNil(AIOLayout.rect(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 25, y: 300), in: bounds))
        XCTAssertNotNil(AIOLayout.rect(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 26, y: 26), in: bounds))
    }

    func testRectRoundsHalfPoints() {
        let r = AIOLayout.rect(from: CGPoint(x: 100.5, y: 200.5), to: CGPoint(x: 300.5, y: 250), in: bounds)!
        for v in [r.minX, r.minY, r.width, r.height] { XCTAssertEqual(v, v.rounded()) }
    }

    func testMoveStopsAtEdges() {
        let r = CGRect(x: 100, y: 100, width: 200, height: 100)
        XCTAssertEqual(AIOLayout.moved(r, by: CGSize(width: 10.4, height: -20.6), in: bounds), CGRect(x: 110, y: 79, width: 200, height: 100))
        XCTAssertEqual(AIOLayout.moved(r, by: CGSize(width: -500, height: 5000), in: bounds), CGRect(x: 0, y: 882, width: 200, height: 100))
        XCTAssertEqual(AIOLayout.moved(r, by: CGSize(width: 5000, height: -500), in: bounds), CGRect(x: 1312, y: 0, width: 200, height: 100))
    }

    func testResizeKeepsOppositeEdgeAndMinSize() {
        let r = CGRect(x: 100, y: 100, width: 200, height: 100)
        XCTAssertEqual(AIOLayout.resized(r, handle: .topRight, to: CGPoint(x: 350, y: 260), in: bounds), CGRect(x: 100, y: 100, width: 250, height: 160))
        XCTAssertEqual(AIOLayout.resized(r, handle: .left, to: CGPoint(x: 50, y: 0), in: bounds), CGRect(x: 50, y: 100, width: 250, height: 100))
        // 反対側を越えて引いても裏返らず、最小サイズで止まる
        XCTAssertEqual(AIOLayout.resized(r, handle: .bottomLeft, to: CGPoint(x: 900, y: 900), in: bounds),
                       CGRect(x: 300 - AIOLayout.minSize, y: 200 - AIOLayout.minSize, width: AIOLayout.minSize, height: AIOLayout.minSize))
        // ディスプレイの外へは広げない
        XCTAssertEqual(AIOLayout.resized(r, handle: .bottom, to: CGPoint(x: 0, y: -300), in: bounds), CGRect(x: 100, y: 0, width: 200, height: 200))
    }

    func testWithSizeKeepsTopLeftAndClamps() {
        let r = CGRect(x: 100, y: 500, width: 200, height: 100) // 左上 = (100, 600)
        XCTAssertEqual(AIOLayout.withSize(r, width: 608, height: 455, in: bounds), CGRect(x: 100, y: 145, width: 608, height: 455))
        XCTAssertEqual(AIOLayout.withSize(r, width: 5000, height: 5000, in: bounds), CGRect(x: 100, y: 0, width: 1412, height: 600))
        XCTAssertEqual(AIOLayout.withSize(r, width: 1, height: 0, in: bounds), CGRect(x: 100, y: 584, width: 16, height: 16))
    }

    func testToolbarGoesBelowThenAboveThenInside() {
        let t = CGSize(width: 400, height: 60)
        // 下に入る
        XCTAssertEqual(AIOLayout.toolbarOrigin(selection: CGRect(x: 500, y: 400, width: 300, height: 200), toolbar: t, bounds: bounds),
                       CGPoint(x: 450, y: 328))
        // 下端に寄せた範囲 → 上
        XCTAssertEqual(AIOLayout.toolbarOrigin(selection: CGRect(x: 500, y: 20, width: 300, height: 200), toolbar: t, bounds: bounds),
                       CGPoint(x: 450, y: 232))
        // 画面いっぱい → 内側の下端
        XCTAssertEqual(AIOLayout.toolbarOrigin(selection: bounds, toolbar: t, bounds: bounds), CGPoint(x: 556, y: 12))
    }

    func testToolbarStaysInsideHorizontally() {
        let t = CGSize(width: 400, height: 60)
        let left = AIOLayout.toolbarOrigin(selection: CGRect(x: 0, y: 400, width: 50, height: 50), toolbar: t, bounds: bounds)
        XCTAssertEqual(left.x, 8)
        let right = AIOLayout.toolbarOrigin(selection: CGRect(x: 1480, y: 400, width: 32, height: 50), toolbar: t, bounds: bounds)
        XCTAssertEqual(right.x, 1512 - 8 - 400)
    }

    func testTopLeftAndGlobalConversion() {
        let local = CGRect(x: 100, y: 700, width: 300, height: 200)
        let tl = AIOLayout.topLeft(local, boundsHeight: 982)
        XCTAssertEqual(tl, CGRect(x: 100, y: 82, width: 300, height: 200))
        // 主画面の右に置いた、高さの違う 2 枚目のディスプレイ
        let second = CGRect(x: 1512, y: -300, width: 2560, height: 1440)
        XCTAssertEqual(AIOLayout.global(CGRect(x: 10, y: 20, width: 100, height: 50), screenFrame: second),
                       CGRect(x: 1522, y: 1070, width: 100, height: 50))
    }
}
