import XCTest

/// Round 28 S (owner, 2026-11-15): Search's song and album rows name the artist ("Song · <artist>", "Album ·
/// <artist>"; VoiceOver "<title>, song by <artist>", "<name>, album by <artist>"), at the default text size and at
/// AX3 (D338). Against the local dev stack only: runs with `MAGPIE_IT=1` (dev-stack address and credentials passed in);
/// guard G0, localhost only.
final class SearchRowsUITests: XCTestCase {
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
    @MainActor private func openSearch(_ arguments: [String]) throws -> (XCUIApplication, XCUIElement) {
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

    /// "aurora": the dev library's Aurora Field songs and albums. Song rows say "song by Aurora Field", album rows
    /// "album by Aurora Field"; the Top result is the artist, whose row doesn't repeat the name ("Artist · 2 albums").
    @MainActor private func checkRows(_ arguments: [String] = []) throws {
        let (app, field) = try openSearch(arguments)
        field.tap()
        field.typeText("aurora")
        let top = app.descendants(matching: .any)["search-top"]
        XCTAssertTrue(top.waitForExistence(timeout: 15), "no Top result for aurora")
        XCTAssertTrue(top.label.hasPrefix("Aurora Field, Artist"), "Top result says \(top.label)")
        XCTAssertFalse(top.label.contains(" by "), "an artist row repeats the artist: \(top.label)")
        app.buttons["Songs"].firstMatch.tap()
        let song = app.buttons["search-song-0"]
        XCTAssertTrue(song.waitForExistence(timeout: 10), "no songs for aurora")
        XCTAssertTrue(song.label.hasSuffix(", song by Aurora Field"), "song row says \(song.label)")
        app.buttons["Albums"].firstMatch.tap()
        let album = app.descendants(matching: .any)["search-album-0"]
        XCTAssertTrue(album.waitForExistence(timeout: 10), "no albums for aurora")
        XCTAssertTrue(album.label.hasSuffix(", album by Aurora Field"), "album row says \(album.label)")
    }

    @MainActor func testSearchSongAndAlbumRowsShowTheArtist() throws {
        try checkRows()
    }

    @MainActor func testSearchSongAndAlbumRowsShowTheArtistAtAX3() throws {
        try checkRows(["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"])   // AX3
    }
}
