import XCTest

final class AskLayoutUITests: XCTestCase {
    func testWideResultsAndLongResponseDoNotCoverComposerOrOptions() {
        let app = XCUIApplication()
        app.launchArguments = ["-language", "en", "-haptics", "NO", "-ui-test-large-ask"]
        app.launch()
        let open = app.buttons["fixture.openAsk"]
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: open)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
        open.tap()
        let options = app.buttons["ask.options"]
        XCTAssertTrue(options.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["ask.run"].isHittable)
        options.tap()
        app.buttons["ask.options.done"].tap()

        // Bring the result into view without moving the composer or close button.
        for _ in 0..<8 {
            if app.buttons["ask.expandResult"].isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(app.buttons["ask.expandResult"].isHittable)
        XCTAssertTrue(app.buttons["ask.run"].isHittable)
        XCTAssertTrue(options.isHittable)
        app.buttons["ask.expandResult"].tap()
        let nextRows = app.buttons["result.rows.next"]
        XCTAssertTrue(nextRows.waitForExistence(timeout: 5))
        nextRows.tap()
        let nextColumns = app.buttons["result.columns.next"]
        if !nextColumns.isHittable { app.swipeUp() }
        nextColumns.tap()
        app.buttons["result.close"].tap()

        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["ask.close"].isHittable)
        app.buttons["ask.close"].tap()
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        XCUIDevice.shared.orientation = .portrait
    }
}
