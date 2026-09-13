import XCTest
@testable import SheetX

final class ResultPresentationTests: XCTestCase {
    func testWideLargeResultHasSmallWindow() {
        let page = ResultPageWindow(rows: 5000, columns: 256, rowPage: 0, columnPage: 0)
        XCTAssertEqual(page.rowRange, 0..<12)
        XCTAssertEqual(page.columnRange, 0..<6)
        XCTAssertEqual(page.rowPageCount, 417)
        XCTAssertEqual(page.columnPageCount, 43)
    }

    func testLastPagesClampAndRemainReachable() {
        let page = ResultPageWindow(rows: 5000, columns: 256, rowPage: 9999, columnPage: 9999)
        XCTAssertEqual(page.rowRange, 4992..<5000)
        XCTAssertEqual(page.columnRange, 252..<256)
        XCTAssertEqual(page.rowPage, 416)
        XCTAssertEqual(page.columnPage, 42)
    }

    func testEmptyOrShrinkingResultCannotCreateInvalidRanges() {
        let page = ResultPageWindow(rows: 0, columns: 0, rowPage: 42, columnPage: 10)
        XCTAssertTrue(page.rowRange.isEmpty)
        XCTAssertTrue(page.columnRange.isEmpty)
        XCTAssertEqual(page.rowPage, 0)
        XCTAssertEqual(page.columnPage, 0)
        let smaller = ResultPageWindow(rows: 2, columns: 1, rowPage: 400, columnPage: 5)
        XCTAssertEqual(smaller.rowRange, 0..<2)
        XCTAssertEqual(smaller.columnRange, 0..<1)
    }

    func testCallerCannotRequestUnboundedCellRendering() {
        let page = ResultPageWindow(rows: Int.max, columns: Int.max, rowPage: Int.max, columnPage: Int.max,
                                    pageSize: Int.max, columnPageSize: Int.max)
        XCTAssertLessThanOrEqual(page.rowRange.count * page.columnRange.count, 400)
    }

    func testLongTextPaginationPreservesUnicodeAndAllContent() {
        let text = String(repeating: "بيانات 👨‍👩‍👧‍👦 🇸🇦 a\u{301}\n", count: 2000)
        let pages = TextPages.split(text, pageSize: 101)
        XCTAssertTrue(pages.allSatisfy { $0.count <= 101 })
        XCTAssertEqual(pages.joined(), text)
        XCTAssertEqual(TextPages.split(""), [""])
    }
}
