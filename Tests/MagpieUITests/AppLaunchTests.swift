import XCTest

final class AppLaunchTests: XCTestCase {
    @MainActor func testLaunchesToConnect() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-MagpieResetState", "YES"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Connect your music"].waitForExistence(timeout: 10))
    }
}
