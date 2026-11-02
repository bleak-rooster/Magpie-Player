import XCTest

/// Round 12 (Y1): search on the phone against the local dev stack. Runs only with `MAGPIE_IT=1 scripts/test-app.sh`
/// (dev-stack address and credentials from `dev/.env.local`). Guard G0: localhost only.
final class SearchUITests: XCTestCase {
    private func devStack() throws -> (url: String, user: String, password: String) {
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
        return (url, user, password)
    }

    /// Signs in to the dev stack and opens the Search tab; returns the app and its search field.
    @MainActor private func openSearch(_ arguments: [String] = []) throws -> (XCUIApplication, XCUIElement) {
        let stack = try devStack()
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-MagpieResetState", "YES", "-MagpieUITesting", "YES", "-MagpieResetLayouts", "YES",
                               "-MagpieNetwork", "wifi"] + arguments
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
        let notNow = app.buttons["Not Now"]   // the save-password prompt (see BrowseFlowTests)
        if notNow.waitForExistence(timeout: 5) {
            for _ in 0..<3 where notNow.exists {
                notNow.tap()
                _ = notNow.waitForNonExistence(timeout: 2)
            }
        }
        XCTAssertTrue(app.tabBars.buttons["Library"].waitForExistence(timeout: 20), "did not reach the tabs")
        let field = app.searchFields.firstMatch
        for _ in 0..<3 where !field.exists {
            app.tabBars.buttons["Search"].tap()
            _ = field.waitForExistence(timeout: 5)
        }
        XCTAssertTrue(field.exists, "search field not found")
        return (app, field)
    }

    /// Plan item 1: a song and its (misspelt) artist in one query. Navidrome finds nothing for the whole query; the
    /// split "dead reckoning" + "cartografers" does, the song is the Top result, and its artist is a row too.
    @MainActor func testSongAndArtistInOneQuery() throws {
        let (app, field) = try openSearch()
        field.tap()
        field.typeText("dead reckoning cartografers")
        let top = app.buttons["search-top"]
        XCTAssertTrue(top.waitForExistence(timeout: 15), "no Top result for a song + artist query")
        XCTAssertTrue(top.label.hasPrefix("Dead Reckoning"), "Top result is \(top.label)")
        app.buttons["Artists"].firstMatch.tap()
        let artist = app.descendants(matching: .any)["search-artist-0"]
        XCTAssertTrue(artist.waitForExistence(timeout: 10), "the song's artist is not a row")
        XCTAssertTrue(artist.label.contains("The Midnight Cartographers"), "artist row is \(artist.label)")
    }

    /// Plan item 3: with 5-row batches, the dev library's 13 "aurora" songs load in three batches as the list
    /// scrolls, then "No more results".
    @MainActor func testSongsLoadMoreAtTheEnd() throws {
        let (app, field) = try openSearch(["-MagpieSearchPageSize", "5"])
        field.tap()
        field.typeText("aurora")
        app.buttons["Songs"].firstMatch.tap()
        XCTAssertTrue(app.buttons["search-song-0"].waitForExistence(timeout: 15), "no songs for aurora")
        // Fix round 1 (I1): nothing loads until the user scrolls, even with the footer on screen.
        let more = app.descendants(matching: .any)["search-more-songs"]
        XCTAssertTrue(more.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["search-song-5"].waitForExistence(timeout: 2), "loaded more without a scroll")
        let end = app.descendants(matching: .any)["search-end-songs"]
        if app.keyboards.buttons["search"].exists { app.keyboards.buttons["search"].tap() }   // the keyboard off the list
        _ = app.keyboards.firstMatch.waitForNonExistence(timeout: 3)
        for _ in 0..<12 where !end.exists {
            app.swipeUp()
            _ = end.waitForExistence(timeout: 2)
        }
        if !end.exists {
            let ids = app.descendants(matching: .any).allElementsBoundByIndex.filter { $0.identifier.hasPrefix("search") }
                .map { "\($0.elementType.rawValue):\($0.identifier):\($0.label.prefix(30))" }
            XCTFail("\"No more results\" never showed; screen: \(ids.joined(separator: " | "))")
        }
        XCTAssertTrue(end.label.contains("No more results"))
        XCTAssertTrue(app.buttons["search-song-12"].exists, "the third batch did not load")
        XCTAssertFalse(app.buttons["search-song-13"].exists, "more rows than the library has: a duplicate")
    }
}
