import XCTest

/// Round 13 (Z2): pull to refresh on the pages (item 2) and the Home and Library reorder buttons (item 13), on the
/// local dev stack. Runs only with `MAGPIE_IT=1 scripts/test-app.sh`. Guard G0: localhost only.
final class Round13UITests: XCTestCase {
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

    @MainActor private func openLibrary(_ app: XCUIApplication, _ row: String) {
        let library = app.tabBars.buttons["Library"]
        let button = app.buttons[row]
        for _ in 0..<3 where !button.exists {
            library.tap()
            _ = button.waitForExistence(timeout: 5)
        }
        button.tap()
    }

    /// One pull to refresh: a drag down from near the top of the page.
    @MainActor private func pull(_ app: XCUIApplication) {
        let window = app.windows.firstMatch
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
        start.press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)))
    }

    /// Never "Couldn't load this" during or after a pull, and the page's content stays on screen throughout.
    @MainActor private func expectRefreshKeepsContent(_ app: XCUIApplication, _ content: XCUIElement, _ name: String) {
        let failure = app.staticTexts["Couldn't load this"]
        for attempt in 1...2 {
            pull(app)
            // The pull reloads at once, then again after the server's quick scan (at most 20 s).
            let deadline = Date().addingTimeInterval(12)
            while Date() < deadline {
                XCTAssertFalse(failure.exists, "\(name), pull \(attempt): the page said it couldn't load")
                XCTAssertTrue(content.exists, "\(name), pull \(attempt): the content went away")
                if failure.exists || !content.exists { break }
                usleep(250_000)
            }
        }
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "\(name)-after-refresh"
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Item 13: Home's and Library's top-right button opens the same editor as Settings, as a sheet; a change shows
    /// at once on the page behind, and Settings' entry is still there. Starts and ends at the default layouts
    /// (-MagpieResetLayouts, then Reset to default order).
    @MainActor func testReorderButtonsOnHomeAndLibrary() throws {
        let app = try launchSignedIn()
        let reset = app.buttons["layout-reset"]
        func flip(_ id: String) {
            let s = app.switches[id]
            for _ in 0..<4 where !s.isHittable { app.swipeUp() }
            s.switches.firstMatch.exists ? s.switches.firstMatch.tap() : s.tap()
        }
        func resetAndClose(_ done: String) {
            for _ in 0..<4 where !reset.exists || !reset.isHittable { app.swipeUp() }
            if reset.isEnabled { reset.tap() }
            XCTAssertFalse(reset.isEnabled, "the default order")
            app.buttons[done].tap()
        }

        // Home: Random albums on from the toolbar's editor.
        let homeTab = app.tabBars.buttons["Home"]
        let editHome = app.buttons["home-edit-toolbar"]
        for _ in 0..<3 where !editHome.exists {
            homeTab.tap()
            _ = editHome.waitForExistence(timeout: 5)
        }
        XCTAssertTrue(editHome.exists, "Home's top-right button")
        XCTAssertEqual(editHome.label, "Edit Home")
        editHome.tap()
        // Round 14: the editor lists 21 sections; Random albums is far down the (lazy) list.
        XCTAssertTrue(app.switches["layout-greeting"].waitForExistence(timeout: 10), "the Home editor, as a sheet")
        for _ in 0..<6 where !app.switches["layout-randomAlbums"].isHittable { app.swipeUp() }
        XCTAssertTrue(app.switches["layout-randomAlbums"].exists)
        flip("layout-randomAlbums")
        XCTAssertEqual(app.switches["layout-randomAlbums"].value as? String, "1")
        app.buttons["home-edit-done"].tap()
        for _ in 0..<6 where !app.staticTexts["home-randomAlbums"].exists { app.swipeUp() }
        XCTAssertTrue(app.staticTexts["home-randomAlbums"].waitForExistence(timeout: 20), "Home follows at once")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "home-after-toolbar-edit"
        shot.lifetime = .keepAlways
        add(shot)
        for _ in 0..<6 { app.swipeDown() }
        editHome.tap()
        XCTAssertTrue(app.switches["layout-greeting"].waitForExistence(timeout: 10))
        resetAndClose("home-edit-done")

        // Library: Songs off from the toolbar's editor.
        let libraryTab = app.tabBars.buttons["Library"]
        let editLibrary = app.buttons["library-edit-toolbar"]
        for _ in 0..<3 where !editLibrary.exists {
            libraryTab.tap()
            _ = editLibrary.waitForExistence(timeout: 5)
        }
        XCTAssertTrue(editLibrary.exists, "Library's top-right button")
        XCTAssertEqual(editLibrary.label, "Edit Library")
        XCTAssertTrue(app.buttons["open-settings"].exists, "Settings stays")
        XCTAssertTrue(app.buttons["library-songs"].exists)
        editLibrary.tap()
        XCTAssertTrue(app.switches["layout-songs"].waitForExistence(timeout: 10), "the Library editor, as a sheet")
        flip("layout-songs")
        XCTAssertEqual(app.switches["layout-songs"].value as? String, "0")
        app.buttons["library-edit-done"].tap()
        XCTAssertTrue(app.buttons["library-songs"].waitForNonExistence(timeout: 10), "Library follows at once")
        editLibrary.tap()
        XCTAssertTrue(app.switches["layout-songs"].waitForExistence(timeout: 10))
        resetAndClose("library-edit-done")
        XCTAssertTrue(app.buttons["library-songs"].waitForExistence(timeout: 10))

        // The Settings entry is still there.
        app.buttons["open-settings"].tap()
        let hub = app.buttons["settings-home-library"]
        for _ in 0..<4 where !hub.exists || !hub.isHittable { app.swipeUp() }
        XCTAssertTrue(hub.waitForExistence(timeout: 10), "Settings › Home & Library stays")
        app.buttons["settings-done"].tap()
    }

    /// Item 2: pull to refresh on an album and an artist never shows an error and keeps the page.
    @MainActor func testPullToRefreshKeepsThePage() throws {
        let app = try launchSignedIn()
        openLibrary(app, "library-albums")
        let album = app.buttons["album-0"]
        XCTAssertTrue(album.waitForExistence(timeout: 15))
        album.tap()
        let track = app.buttons["track-0"]
        XCTAssertTrue(track.waitForExistence(timeout: 15))
        expectRefreshKeepsContent(app, track, "album")

        app.navigationBars.buttons.firstMatch.tap()
        app.navigationBars.buttons.firstMatch.tap()
        openLibrary(app, "library-artists")
        let aurora = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Aurora Field'")).firstMatch
        XCTAssertTrue(aurora.waitForExistence(timeout: 15))
        aurora.tap()
        let more = app.buttons["artist-more"]
        XCTAssertTrue(more.waitForExistence(timeout: 15))
        expectRefreshKeepsContent(app, more, "artist")
    }
}
