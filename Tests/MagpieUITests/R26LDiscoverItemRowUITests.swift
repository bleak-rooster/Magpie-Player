import XCTest

/// Round 26 L fix round 1 (M4, D271): an Aurral item no Navidrome playlist is known to be is a row of its own in
/// Library › Discover. It shows, says why it can't open ("Not ready yet. Check back later."), and doesn't navigate.
/// Dev stack plus the localhost stub Aurral's `same-name-elsewhere` scenario (`dev/aurral-stub`): two shared playlists
/// "Late Night Chill", the signed-in user's and "sam"'s, neither in Navidrome. Guard G0: localhost only.
final class R26LDiscoverItemRowUITests: XCTestCase {
    private struct Stack {
        var url: String
        var user: String
        var password: String
        var aurral: URL
    }

    private func stack() throws -> Stack {
        let env = ProcessInfo.processInfo.environment
        guard env["MAGPIE_IT"] == "1" else { throw XCTSkip("set MAGPIE_IT=1 (MAGPIE_IT=1 scripts/test-app.sh) to run") }
        guard let url = env["MAGPIE_IT_URL"], let user = env["MAGPIE_IT_USER"], let password = env["MAGPIE_IT_PASSWORD"],
              let aurralText = env["MAGPIE_IT_AURRAL_URL"], let aurral = URL(string: aurralText),
              !url.isEmpty, !user.isEmpty, !password.isEmpty else {
            XCTFail("MAGPIE_IT=1 but the dev stack or the stub Aurral wasn't passed in")
            throw XCTSkip("missing dev-stack environment")
        }
        for address in [URLComponents(string: url)?.host, aurral.host()] {
            guard let host = address, ["127.0.0.1", "localhost"].contains(host) else {
                XCTFail("Refusing to run against a non-local server; the UI test only talks to the dev stack")
                throw XCTSkip("non-local server")
            }
        }
        return Stack(url: url, user: user, password: password, aurral: aurral)
    }

    @MainActor private func signIn(_ app: XCUIApplication, _ s: Stack, scenario: String) {
        let address = app.textFields["connect-address-0"]
        XCTAssertTrue(address.waitForExistence(timeout: 10))
        address.tap()
        address.typeText(s.url)
        app.textFields["connect-username"].tap()
        app.textFields["connect-username"].typeText(s.user)
        app.secureTextFields["connect-password"].tap()
        app.secureTextFields["connect-password"].typeText(s.password)
        app.buttons["connect-continue"].tap()
        let notNow = app.buttons["Not Now"]
        if notNow.waitForExistence(timeout: 5) {
            for _ in 0..<3 where notNow.exists { notNow.tap(); _ = notNow.waitForNonExistence(timeout: 2) }
        }
        XCTAssertTrue(app.tabBars.buttons["Library"].waitForExistence(timeout: 20), "did not reach the tabs")
        let settings = app.buttons["open-settings"]
        for _ in 0..<3 where !settings.exists {
            app.tabBars.buttons["Library"].tap()
            _ = settings.waitForExistence(timeout: 5)
        }
        settings.tap()
        let row = app.buttons["settings-aurral"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        let aurralAddress = app.textFields["aurral-address"]
        XCTAssertTrue(aurralAddress.waitForExistence(timeout: 10))
        aurralAddress.tap()
        aurralAddress.typeText(s.aurral.appending(path: "s/\(scenario)").absoluteString)
        app.textFields["aurral-username"].tap()
        app.textFields["aurral-username"].typeText("magpie")
        app.secureTextFields["aurral-password"].tap()
        app.secureTextFields["aurral-password"].typeText("stub-aurral-password")
        app.buttons["aurral-sign-in"].tap()
        if notNow.waitForExistence(timeout: 4) { notNow.tap() }
        XCTAssertTrue(app.descendants(matching: .any)["aurral-user"].waitForExistence(timeout: 20), "signed in to the stub")
        app.navigationBars.buttons.element(boundBy: 0).tap()   // back to Settings
        let done = app.buttons["settings-done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        done.tap()
    }

    @MainActor func testAnItemNotInNavidromeShowsSaysWhyAndDoesNotOpen() throws {
        let s = try stack()
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-MagpieResetState", "YES", "-MagpieUITesting", "YES", "-MagpieNetwork", "wifi"]
        app.launch()
        signIn(app, s, scenario: "same-name-elsewhere")
        app.tabBars.buttons["Library"].tap()
        let discover = app.buttons["library-discover"]
        for _ in 0..<4 where !discover.isHittable { app.swipeUp() }
        XCTAssertTrue(discover.waitForExistence(timeout: 15), "Library › Discover")
        discover.tap()

        // Only mine (the default): the user's own row, once; Sam's isn't listed.
        let mine = app.descendants(matching: .any)["discover-item-sp-chill-mine"].firstMatch
        XCTAssertTrue(mine.waitForExistence(timeout: 20), "the user's own item is a row of its own")
        XCTAssertTrue(mine.label.contains("Late Night Chill"), mine.label)
        XCTAssertTrue(mine.label.contains("Not ready yet"), "it says why it doesn't open: \(mine.label)")
        XCTAssertFalse(app.descendants(matching: .any)["discover-item-sp-chill-sam"].exists, "another user's: only under everyone's")

        // Tapping it goes nowhere: still Library › Discover, the row still there.
        mine.tap()
        XCTAssertTrue(app.navigationBars["Discover"].waitForExistence(timeout: 3), "still on Discover")
        XCTAssertTrue(mine.exists)
        XCTAssertFalse(app.descendants(matching: .any)["discover-song-0"].exists, "no playlist page opened")
    }
}
