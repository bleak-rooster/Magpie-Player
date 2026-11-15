import XCTest

/// Round 28 O1 (owner, 2026-11-15, D323, D329): the Offline mode switch at the top of Settings, its state line, the
/// notice it brings ("Offline mode is on" with Go online) and Go online turning it off again. Each test leaves Offline
/// mode off (it is a preference and outlives the app). Runs only with `MAGPIE_IT=1` (the dev stack; G0: localhost only).
final class OfflineSwitchUITests: XCTestCase {
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
        app.launchArguments = ["-MagpieResetState", "YES", "-MagpieUITesting", "YES", "-MagpieNetwork", "wifi"]
        app.launch()
        let address = app.textFields["connect-address-0"]
        if address.waitForExistence(timeout: 10) {
            address.tap()
            address.typeText(url)
            let userField = app.textFields["connect-username"]
            userField.tap()
            userField.typeText(user)
            let passwordField = app.secureTextFields["connect-password"]
            passwordField.tap()
            passwordField.typeText(password)
            app.buttons["connect-continue"].tap()
        }
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

    @MainActor private func openSettings(_ app: XCUIApplication) -> XCUIElement {
        let library = app.tabBars.buttons["Library"]
        let settings = app.buttons["open-settings"]
        for _ in 0..<3 where !settings.exists {
            library.tap()
            _ = settings.waitForExistence(timeout: 5)
        }
        settings.tap()
        let offline = app.switches["settings-offline-mode"]
        XCTAssertTrue(offline.waitForExistence(timeout: 10), "Offline mode is Settings' first row")
        return offline
    }

    /// The switch's own control, at its trailing edge (tapping the row's title may not reach it).
    @MainActor private func flip(_ toggle: XCUIElement) {
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
    }

    @MainActor private func value(_ element: XCUIElement) -> String { element.value as? String ?? "" }

    @MainActor func testOfflineModeSwitchInSettings() throws {
        let app = try launchSignedIn()
        let offline = openSettings(app)
        // Above Accounts & Servers, saying what happens now.
        let accounts = app.staticTexts["settings-accounts-header"]
        if accounts.exists { XCTAssertLessThan(offline.frame.minY, accounts.frame.minY) }
        if value(offline).hasPrefix("On") { flip(offline) }   // an earlier run left it on
        expectation(for: NSPredicate(format: "value BEGINSWITH 'Off'"), evaluatedWith: offline)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(value(offline).contains("Goes offline by itself if your library is out of reach"), value(offline))
        flip(offline)
        expectation(for: NSPredicate(format: "value BEGINSWITH 'On'"), evaluatedWith: offline)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(value(offline).contains("Only music on this phone plays"), value(offline))
        XCTAssertTrue(app.staticTexts["Only music on this phone plays"].exists, "the state line shows under the title")
        // Downloads & Storage: Go offline automatically, with its footer.
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Downloads'")).firstMatch.tap()
        let automatic = app.switches["settings-offline-automatic"]
        for _ in 0..<6 where !automatic.isHittable { app.swipeUp() }
        XCTAssertTrue(automatic.exists && automatic.label == "Go offline automatically")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        // Back off: nothing is left on for the next test.
        flip(offline)
        expectation(for: NSPredicate(format: "value BEGINSWITH 'Off'"), evaluatedWith: offline)
        waitForExpectations(timeout: 5)
        app.buttons["settings-done"].tap()
    }

    @MainActor func testGoOnlineFromTheNotice() throws {
        let app = try launchSignedIn()
        let offline = openSettings(app)
        if value(offline).hasPrefix("Off") { flip(offline) }
        expectation(for: NSPredicate(format: "value BEGINSWITH 'On'"), evaluatedWith: offline)
        waitForExpectations(timeout: 5)
        app.buttons["settings-done"].tap()
        // Library shows the notice: who chose it, and the way back.
        app.tabBars.buttons["Library"].tap()
        let notice = app.staticTexts["Offline mode is on"]
        XCTAssertTrue(notice.waitForExistence(timeout: 10))
        let goOnline = app.buttons["offline-go-online"]
        XCTAssertTrue(goOnline.exists && goOnline.label == "Go online")
        XCTAssertGreaterThanOrEqual(goOnline.frame.height, 44, "a 44 pt target")
        goOnline.tap()
        XCTAssertTrue(notice.waitForNonExistence(timeout: 10), "Go online turns Offline mode off")
        let again = openSettings(app)
        XCTAssertTrue(value(again).hasPrefix("Off"), value(again))
        app.buttons["settings-done"].tap()
    }
}
