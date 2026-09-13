import XCTest

final class AISettingsUITests: XCTestCase {
    func testProviderAndModelSelectionStaysResponsive() {
        let app = XCUIApplication()
        app.launchArguments = ["-language", "en", "-haptics", "NO"]
        app.launch()
        app.tabBars.buttons["Settings"].tap()
        let aiSettings = app.buttons["ai.settings"]
        if !aiSettings.isHittable { app.swipeUp() }
        XCTAssertTrue(aiSettings.waitForExistence(timeout: 5))
        aiSettings.tap()

        // No API keys and no network are needed to open the picker or use suggestions.
        for (provider, model) in [("groq", "llama-3.1-8b-instant"), ("gemini", "gemini-2.5-flash-lite")] {
            app.buttons["ai.provider.\(provider)"].tap()
            let choose = app.buttons["ai.chooseModel"]
            XCTAssertTrue(choose.waitForExistence(timeout: 5))
            choose.tap()
            let search = app.searchFields.firstMatch
            XCTAssertTrue(search.waitForExistence(timeout: 5))
            search.tap()
            search.typeText(model)
            let option = app.buttons["ai.modelOption.\(model)"]
            XCTAssertTrue(option.waitForExistence(timeout: 5))
            option.tap()
            let field = app.textFields["ai.model"]
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            XCTAssertEqual(field.value as? String, model)
            app.buttons["ai.cancel"].tap()
            XCTAssertTrue(app.buttons["ai.provider.\(provider)"].waitForExistence(timeout: 5))
        }
    }
}
