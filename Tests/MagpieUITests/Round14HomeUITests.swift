import XCTest

/// Round 14 A6: the Spotify-style Home on the local dev stack (Navidrome only, no Aurral): the greeting, the chips
/// (no Discover or Recommended without Aurral), and Edit Home: a switch, a shelf's card size and Reset apply at once.
/// Runs only with MAGPIE_IT=1. Guard G0: localhost only.
final class Round14HomeUITests: XCTestCase {
    private struct DevStack {
        var url: String
        var user: String
        var password: String
    }

    private func devStack() throws -> DevStack {
        let env = ProcessInfo.processInfo.environment
        guard env["MAGPIE_IT"] == "1" else { throw XCTSkip("set MAGPIE_IT=1 (MAGPIE_IT=1 scripts/test-app.sh) to run") }
        guard let url = env["MAGPIE_IT_URL"], let user = env["MAGPIE_IT_USER"], let password = env["MAGPIE_IT_PASSWORD"],
              !url.isEmpty, !user.isEmpty, !password.isEmpty else {
            XCTFail("MAGPIE_IT=1 but the dev-stack URL/credentials were not passed in")
            throw XCTSkip("missing dev-stack environment")
        }
        guard let host = URLComponents(string: url)?.host, ["127.0.0.1", "localhost"].contains(host) else {
            XCTFail("Refusing to run against a non-local server (\(url)); the UI test only talks to the dev stack")
            throw XCTSkip("non-local server")
        }
        return DevStack(url: url, user: user, password: password)
    }

    @MainActor private func launchSignedIn() throws -> XCUIApplication {
        let stack = try devStack()
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-MagpieResetState", "YES", "-MagpieUITesting", "YES", "-MagpieResetLayouts", "YES",
                               "-MagpieNetwork", "wifi"]
        app.launch()
        let address = app.textFields["connect-address-0"]
        XCTAssertTrue(address.waitForExistence(timeout: 10))
        address.tap()
        address.typeText(stack.url)
        let user = app.textFields["connect-username"]
        user.tap()
        user.typeText(stack.user)
        let password = app.secureTextFields["connect-password"]
        password.tap()
        password.typeText(stack.password)
        app.buttons["connect-continue"].tap()
        let notNow = app.buttons["Not Now"]
        if notNow.waitForExistence(timeout: 5) {
            for _ in 0..<3 where notNow.exists {
                notNow.tap()
                _ = notNow.waitForNonExistence(timeout: 2)
            }
        }
        XCTAssertTrue(app.tabBars.buttons["Library"].waitForExistence(timeout: 20), "did not reach the tabs")
        return app
    }

    @MainActor private func shot(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor func testEditHomeAppliesAtOnce() throws {
        let app = try launchSignedIn()
        let greeting = app.staticTexts["home-greeting"]
        for _ in 0..<3 where !greeting.exists {
            app.tabBars.buttons["Home"].tap()
            _ = greeting.waitForExistence(timeout: 10)
        }
        XCTAssertTrue(greeting.waitForExistence(timeout: 20), "the greeting heads Home")
        XCTAssertTrue(["Good morning", "Good afternoon", "Good evening"].contains(greeting.label))
        let all = app.buttons["home-chip-all"], library = app.buttons["home-chip-library"]
        XCTAssertTrue(all.waitForExistence(timeout: 20) && library.exists, "All and Your library")
        XCTAssertFalse(app.buttons["home-chip-discover"].exists, "no Discover chip without the service")
        XCTAssertFalse(app.buttons["home-chip-recommended"].exists)
        XCTAssertTrue(all.isSelected)
        library.tap()
        XCTAssertTrue(library.isSelected && greeting.exists, "the chips narrow Home; the greeting stays")
        all.tap()
        shot(app, "home-spotify-style")

        // Edit Home from the greeting: Filters off, Recently added's cards large.
        // Fix round 1: the greeting carries no Edit Home of its own; the toolbar button (and the bottom one) open it.
        XCTAssertFalse(app.buttons["home-greeting-edit"].exists, "no third Edit Home control")
        app.buttons["home-edit-toolbar"].tap()
        let chips = app.switches["layout-filterChips"]
        XCTAssertTrue(chips.waitForExistence(timeout: 10), "the Home editor, as a sheet")
        XCTAssertEqual(chips.value as? String, "1")
        (chips.switches.firstMatch.exists ? chips.switches.firstMatch : chips).tap()
        XCTAssertEqual(chips.value as? String, "0")
        let settings = app.buttons["layout-settings-recentlyAdded"]
        for _ in 0..<4 where !settings.isHittable { app.swipeUp() }
        XCTAssertEqual(settings.value as? String, "Medium cards, 12 items")
        settings.tap()
        let size = app.buttons["Card size"]
        XCTAssertTrue(size.waitForExistence(timeout: 5), "the shelf's settings menu")
        size.tap()
        let large = app.buttons["Large"]
        XCTAssertTrue(large.waitForExistence(timeout: 5))
        large.tap()
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        XCTAssertEqual(settings.value as? String, "Large cards, 12 items", "saved at once")
        let trending = app.switches["layout-trending"]
        for _ in 0..<6 where !trending.isHittable { app.swipeUp() }
        XCTAssertTrue(app.staticTexts["Needs Aurral"].exists, "a section whose service is missing says so")
        shot(app, "home-editor-round14")
        app.buttons["home-edit-done"].tap()
        XCTAssertTrue(all.waitForNonExistence(timeout: 10), "Home follows at once: no chips")
        XCTAssertTrue(greeting.exists)

        // Reset restores the order, the switches and the settings.
        app.buttons["home-edit-toolbar"].tap()
        let reset = app.buttons["layout-reset"]
        XCTAssertTrue(chips.waitForExistence(timeout: 10))
        for _ in 0..<8 where !reset.isHittable { app.swipeUp() }
        XCTAssertTrue(reset.isEnabled)
        reset.tap()
        XCTAssertFalse(reset.isEnabled, "the default")
        app.buttons["home-edit-done"].tap()
        XCTAssertTrue(all.waitForExistence(timeout: 10), "the chips are back")
    }
}
