import XCTest

final class AppLaunchTests: XCTestCase {
    @MainActor func testLaunchesToConnect() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-MagpieResetState", "YES", "-MagpieUITesting", "YES", "-MagpieNetwork", "wifi"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Your music server"].waitForExistence(timeout: 10))
    }
}
