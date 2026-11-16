import XCTest

/// Round 28 O3 (owner, 2026-11-15, item 1: "when music is downloaded, you should be able to access the page with that
/// music, like an album should still open the album of the downloaded music … only downloaded songs are visible"; D340,
/// D341): in Offline mode Library keeps its rows and an album opens from the phone with only its downloaded songs. Each
/// test leaves Offline mode off and removes what it downloaded. Runs only with `MAGPIE_IT=1` (the dev stack; G0:
/// localhost only).
final class OfflinePagesUITests: XCTestCase {
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

    /// Turns Offline mode on or off from Settings (O1's switch), then closes Settings.
    @MainActor private func setOfflineMode(_ on: Bool, _ app: XCUIApplication) {
        let library = app.tabBars.buttons["Library"]
        let settings = app.buttons["open-settings"]
        for _ in 0..<3 where !settings.exists {
            library.tap()
            _ = settings.waitForExistence(timeout: 5)
        }
        settings.tap()
        let toggle = app.switches["settings-offline-mode"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        if (toggle.value as? String ?? "").hasPrefix(on ? "Off" : "On") {
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        }
        expectation(for: NSPredicate(format: "value BEGINSWITH %@", on ? "On" : "Off"), evaluatedWith: toggle)
        waitForExpectations(timeout: 10)
        app.buttons["settings-done"].tap()
    }

    /// Back to Library's root.
    @MainActor private func libraryRoot(_ app: XCUIApplication) {
        let library = app.tabBars.buttons["Library"]
        library.tap()
        for _ in 0..<4 where !app.buttons["open-settings"].exists {
            library.tap()
            _ = app.buttons["open-settings"].waitForExistence(timeout: 2)
        }
    }

    @MainActor func testOfflineLibraryKeepsItsRows() throws {
        let app = try launchSignedIn()
        setOfflineMode(true, app)
        libraryRoot(app)
        let notice = app.staticTexts["Offline mode is on"]
        XCTAssertTrue(notice.waitForExistence(timeout: 10), "the notice, as a top inset")
        XCTAssertTrue(app.buttons["offline-go-online"].exists, "with its way back")
        let rows = ["playlists", "artists", "albums", "songs", "genres", "downloads"]
        for row in rows {
            XCTAssertTrue(app.buttons["library-\(row)"].exists, "\(row) stays offline")
        }
        // The owner's order, under the notice.
        let frames = rows.map { app.buttons["library-\($0)"].frame.minY }
        XCTAssertEqual(frames, frames.sorted(), "rows in the owner's order")
        XCTAssertLessThan(notice.frame.minY, frames[0], "the notice sits above the rows")
        for row in ["favourites", "requests", "finds", "trending", "recommended", "discover"] {
            XCTAssertFalse(app.buttons["library-\(row)"].exists, "\(row) needs the server (or Aurral)")
        }
        XCTAssertFalse(app.descendants(matching: .any)["library-recently-added"].exists, "no Recently added grid")
        // A fresh install has nothing downloaded: a list opened offline says so, in so many words.
        app.buttons["library-albums"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["offline-empty"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Nothing downloaded yet"].exists)
        libraryRoot(app)
        setOfflineMode(false, app)
    }

    @MainActor func testOfflineAlbumOpensWithOnlyItsDownloadedSongs() throws {
        let app = try launchSignedIn()
        libraryRoot(app)
        app.buttons["library-albums"].tap()
        // The first album with more than one song.
        var opened = false
        for index in 0..<6 {
            let tile = app.buttons["album-\(index)"]
            guard tile.waitForExistence(timeout: 10) else { break }
            tile.tap()
            if app.buttons["track-1"].waitForExistence(timeout: 10) { opened = true; break }
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
        XCTAssertTrue(opened, "the dev stack has an album with two songs")
        let title = app.navigationBars.firstMatch.staticTexts.firstMatch.label
        // Download only its first song.
        app.buttons["track-0"].press(forDuration: 1.0)
        let download = app.collectionViews.buttons["Download"]   // the menu's, not the page's capsule
        XCTAssertTrue(download.waitForExistence(timeout: 5))
        download.tap()
        var landed = false
        for _ in 0..<10 where !landed {
            app.buttons["track-0"].press(forDuration: 1.0)
            landed = app.collectionViews.buttons["Remove download"].waitForExistence(timeout: 3)
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()   // close the menu
        }
        XCTAssertTrue(landed, "the song landed")
        setOfflineMode(true, app)
        libraryRoot(app)
        app.buttons["library-albums"].tap()
        let tile = app.buttons["album-0"]
        XCTAssertTrue(tile.waitForExistence(timeout: 10), "the album is on the phone")
        tile.tap()
        XCTAssertTrue(app.buttons["track-0"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["track-1"].exists, "only the downloaded song")
        let count = app.descendants(matching: .any)["on-phone-count"]
        XCTAssertTrue(count.exists && count.label.contains("of") && count.label.hasSuffix("songs on this phone"), count.label)
        XCTAssertFalse(app.buttons["favourite-button"].exists, "Favourite hides offline")
        if !title.isEmpty { XCTAssertTrue(app.navigationBars[title].exists || app.staticTexts[title].exists) }
        // Clean up: back online, the download removed.
        setOfflineMode(false, app)
        libraryRoot(app)
        app.buttons["library-downloads"].tap()
        let song = app.buttons["Songs"]
        if song.waitForExistence(timeout: 5) { song.tap() }
        let row = app.buttons["downloads-song-0"]
        if row.waitForExistence(timeout: 10) {
            row.press(forDuration: 1.0)
            app.collectionViews.buttons["Remove download"].tap()
            let confirm = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Remove'")).firstMatch
            if confirm.waitForExistence(timeout: 5) { confirm.tap() }
        }
    }
}
