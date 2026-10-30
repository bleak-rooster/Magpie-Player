import XCTest

/// P1: Settings › Downloads & Storage › Downloading now. The network is pinned to mobile data, so an album's download
/// waits for Wi-Fi and stays listed; Cancel all then clears it (nothing is left on the simulator).
/// Runs only with `MAGPIE_IT=1` (the dev stack; G0: localhost only).
final class DownloadingNowUITests: XCTestCase {
    @MainActor private func launchSignedIn() throws -> XCUIApplication {
        let env = ProcessInfo.processInfo.environment
        guard env["MAGPIE_IT"] == "1" else { throw XCTSkip("set MAGPIE_IT=1 (MAGPIE_IT=1 scripts/test-app.sh) to run") }
        guard let url = env["MAGPIE_IT_URL"], let user = env["MAGPIE_IT_USER"], let password = env["MAGPIE_IT_PASSWORD"],
              !url.isEmpty, !user.isEmpty, !password.isEmpty else {
            XCTFail("MAGPIE_IT=1 but the dev-stack URL/credentials were not passed in")
            throw XCTSkip("missing dev-stack environment")
        }
        guard let host = URLComponents(string: url)?.host, ["127.0.0.1", "localhost"].contains(host) else {
            XCTFail("Refusing to run against a non-local server (\(url))")
            throw XCTSkip("non-local server")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-MagpieResetState", "YES", "-MagpieUITesting", "YES", "-MagpieNetwork", "cellular"]
        app.launch()
        let address = app.textFields["connect-address-0"]
        XCTAssertTrue(address.waitForExistence(timeout: 10))
        address.tap()
        address.typeText(url)
        let userField = app.textFields["connect-username"]
        userField.tap()
        userField.typeText(user)
        let passwordField = app.secureTextFields["connect-password"]
        passwordField.tap()
        passwordField.typeText(password)
        app.buttons["connect-continue"].tap()
        let notNow = app.buttons["Not Now"]
        if notNow.waitForExistence(timeout: 5) {
            for _ in 0..<3 where notNow.exists {
                notNow.tap()
                _ = notNow.waitForNonExistence(timeout: 2)
            }
        }
        XCTAssertTrue(app.tabBars.buttons["Library"].waitForExistence(timeout: 20))
        return app
    }

    @MainActor func testOpenDownloadingNowFromSettings() throws {
        let app = try launchSignedIn()
        let library = app.tabBars.buttons["Library"]
        let albums = app.buttons["library-albums"]
        for _ in 0..<3 where !albums.exists {
            library.tap()
            _ = albums.waitForExistence(timeout: 5)
        }
        albums.tap()
        let firstAlbum = app.buttons["album-0"]
        XCTAssertTrue(firstAlbum.waitForExistence(timeout: 15))
        firstAlbum.tap()
        let download = app.buttons.matching(NSPredicate(format: "label == %@ AND identifier == %@", "Download", "download")).firstMatch
        XCTAssertTrue(download.waitForExistence(timeout: 15))
        download.tap()
        expectation(for: NSPredicate(format: "value == 'Waiting for Wi-Fi'"), evaluatedWith: download)
        waitForExpectations(timeout: 15)

        // Library › Settings › Downloads & Storage › Downloading now.
        library.tap()
        let settings = app.buttons["open-settings"]
        for _ in 0..<3 where !settings.exists {
            library.tap()
            _ = settings.waitForExistence(timeout: 5)
        }
        settings.tap()
        let downloads = app.buttons["settings-downloads"]
        XCTAssertTrue(downloads.waitForExistence(timeout: 10))
        downloads.tap()
        let now = app.buttons["settings-downloading-now"]
        XCTAssertTrue(now.waitForExistence(timeout: 10), "Downloading now shows while something downloads")
        XCTAssertTrue(now.label.hasPrefix("Downloading now \u{00B7} "), now.label)
        now.tap()
        XCTAssertTrue(app.staticTexts["Keep Magpie open to finish downloading"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Waiting for Wi-Fi"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["downloading-cancel"].firstMatch.exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "downloading-now"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        // Cancel all, confirmed: the list empties and nothing is left downloading.
        app.buttons["downloads-cancel-all"].tap()
        let confirm = app.buttons["Cancel all downloads"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(app.otherElements["downloading-now-empty"].waitForExistence(timeout: 10)
                      || app.staticTexts["Nothing downloading"].waitForExistence(timeout: 5))
    }
}
