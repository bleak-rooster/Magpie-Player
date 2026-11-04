import XCTest

/// Round 14 A4: Library › Trending, Recommended and Discover (For you, Browse more playlists, a Discover playlist) on
/// the dev stack with the localhost stub Aurral (`dev/aurral-stub`, region AU, so nothing reaches the internet). Owner
/// answer 2: the server's name never appears on these screens; every text on each is scanned. Guard G0: localhost only.
final class Round14DiscoverUITests: XCTestCase {
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

    /// Every text and button label on screen; none may name the services (owner answer 2).
    @MainActor private func assertNoServiceNames(_ app: XCUIApplication, _ screen: String, file: StaticString = #filePath, line: UInt = #line) {
        let labels = (app.staticTexts.allElementsBoundByIndex + app.buttons.allElementsBoundByIndex).map { $0.label }
        // A curator named after its service ("Deezer Pop Editor") is the playlist's own data, not Magpie's words.
        for name in ["Aurral", "Lidarr", "Navidrome"] {
            let hits = labels.filter { $0.localizedCaseInsensitiveContains(name) }
            XCTAssertTrue(hits.isEmpty, "\(screen) names \(name): \(hits)", file: file, line: line)
        }
    }

    @MainActor private func signIn(_ app: XCUIApplication, _ s: Stack) {
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
        aurralAddress.typeText(s.aurral.appending(path: "s/default").absoluteString)
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

    @MainActor private func open(_ app: XCUIApplication, row: String) {
        let element = app.buttons["library-\(row)"]
        for _ in 0..<4 where !element.isHittable { app.swipeUp() }
        XCTAssertTrue(element.waitForExistence(timeout: 15), "Library › \(row)")
        element.tap()
    }

    @MainActor func testTrendingRecommendedAndDiscoverNeverNameTheServer() throws {
        let s = try stack()
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-MagpieResetState", "YES", "-MagpieUITesting", "YES", "-MagpieNetwork", "wifi"]
        app.launch()
        signIn(app, s)
        app.tabBars.buttons["Library"].tap()

        // Trending: the No. 1 song, Top songs, Charts by genre.
        open(app, row: "trending")
        XCTAssertTrue(app.descendants(matching: .any)["trending-spotlight"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["Harbour Lights"].firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any)["trending-song-0"].waitForExistence(timeout: 10))
        assertNoServiceNames(app, "Trending")
        for _ in 0..<6 where !app.descendants(matching: .any)["genre-chart-132"].exists { app.swipeUp() }
        app.descendants(matching: .any)["genre-chart-132"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["genre-song-0"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Worldwide"].firstMatch.exists)
        assertNoServiceNames(app, "Charts by genre")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // Recommended: the top pick and All.
        open(app, row: "recommended")
        XCTAssertTrue(app.descendants(matching: .any)["recommended-top-pick"].waitForExistence(timeout: 20))
        assertNoServiceNames(app, "Recommended")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // Discover: For you underneath, Browse more playlists, a playlist with Add flow (the stub user is an admin).
        open(app, row: "discover")
        let browse = app.buttons["discover-browse-more"]
        XCTAssertTrue(browse.waitForExistence(timeout: 20))
        assertNoServiceNames(app, "Discover")
        browse.tap()
        let playlist = app.buttons["discover-playlist-908622995"].firstMatch
        XCTAssertTrue(playlist.waitForExistence(timeout: 20))
        assertNoServiceNames(app, "Browse more playlists")
        playlist.tap()
        XCTAssertTrue(app.descendants(matching: .any)["discover-song-0"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["add-flow"].exists || app.descendants(matching: .any)["add-flow-state"].exists)
        assertNoServiceNames(app, "A Discover playlist")
    }
}
