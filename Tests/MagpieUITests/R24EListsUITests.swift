import XCTest

/// Round 24 E (owner, 2026-11-08): a recent search's whole row is tappable (D226), and Library › Songs' own search field
/// gives back the letter list where it was when cleared (D224). Against the local dev stack: `MAGPIE_IT=1
/// scripts/test-app.sh`. Guard G0: localhost only.
final class R24EListsUITests: XCTestCase {
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
        let notNow = app.buttons["Not Now"]   // the save-password prompt (see BrowseFlowTests)
        if notNow.waitForExistence(timeout: 5) {
            for _ in 0..<3 where notNow.exists {
                notNow.tap()
                _ = notNow.waitForNonExistence(timeout: 2)
            }
        }
        XCTAssertTrue(app.tabBars.buttons["Library"].waitForExistence(timeout: 20), "did not reach the tabs")
        return app
    }

    /// Item 9: a tap on the far right of a recent search's row, well past the query's text, runs that search.
    @MainActor func testRecentRowTapOnTrailingSpaceRunsSearch() throws {
        let app = try launchSignedIn()
        let field = app.searchFields.firstMatch
        for _ in 0..<3 where !field.exists {
            app.tabBars.buttons["Search"].tap()
            _ = field.waitForExistence(timeout: 5)
        }
        XCTAssertTrue(field.exists, "search field not found")
        field.tap()
        field.typeText("aurora")
        // Playing a result keeps the search as a recent one.
        let song = app.buttons["search-song-0"]
        XCTAssertTrue(song.waitForExistence(timeout: 15), "no results for aurora")
        song.tap()
        let close = app.buttons["Close"].exists ? app.buttons["Close"] : app.buttons["Cancel"]
        close.firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["search-scope"].waitForNonExistence(timeout: 5), "still searching")

        let recent = app.buttons["aurora"].firstMatch
        XCTAssertTrue(recent.waitForExistence(timeout: 5), "aurora is not a recent search")
        let window = app.windows.firstMatch.frame
        XCTAssertGreaterThan(recent.frame.width, window.width * 0.7, "the row runs the width of the screen")
        // 90 % across the row: empty space, nowhere near the word "aurora".
        recent.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertTrue(app.descendants(matching: .any)["search-scope"].waitForExistence(timeout: 15),
                      "a tap on the row's empty trailing space did not run the search")
    }

    /// Item 4: Library › Songs has its own search field at the top; a query shows only songs, without the A–Z bar;
    /// clearing it gives back the letter list where it was (here: at T, after a jump).
    @MainActor func testSongsSearchFieldClearReturnsToTheSamePlace() throws {
        let app = try launchSignedIn()
        let library = app.tabBars.buttons["Library"]
        let songs = app.buttons["library-songs"]
        for _ in 0..<3 where !songs.exists {
            library.tap()
            _ = songs.waitForExistence(timeout: 5)
        }
        songs.tap()
        XCTAssertTrue(app.buttons["song-0"].waitForExistence(timeout: 15))
        let index = app.descendants(matching: .any)["letter-index"]
        XCTAssertTrue(index.waitForExistence(timeout: 5), "the letter index")
        index.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0))
            .withOffset(CGVector(dx: 0, dy: 8 + 20.5 * 13)).tap()   // T
        let terra = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Terra Incognita'")).firstMatch
        XCTAssertTrue(terra.waitForExistence(timeout: 5))
        XCTAssertTrue(terra.isHittable, "scrolled to T")

        let field = app.textFields["kind-search-songs"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "no search field on Songs")
        XCTAssertEqual(field.placeholderValue, "Search songs")
        field.tap()
        field.typeText("aurora")
        XCTAssertTrue(app.buttons["kind-result-song-0"].waitForExistence(timeout: 15), "no songs for aurora")
        XCTAssertTrue(index.waitForNonExistence(timeout: 5), "the A–Z bar is hidden while searching")
        XCTAssertFalse(terra.exists && terra.isHittable, "the letter list is under the results")

        app.buttons["kind-search-clear"].tap()
        XCTAssertTrue(app.buttons["kind-result-song-0"].waitForNonExistence(timeout: 5), "results still shown")
        XCTAssertTrue(index.waitForExistence(timeout: 5), "the A–Z bar is back")
        XCTAssertTrue(terra.waitForExistence(timeout: 5))
        XCTAssertTrue(terra.isHittable, "back at T, where the list was")
        XCTAssertFalse(app.buttons["song-0"].isHittable, "not back at the top")
    }
}
