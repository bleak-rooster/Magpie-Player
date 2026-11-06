import XCTest

/// Round 23 (owner, 2026-11-07, D201): All / Songs / Artists / Albums stay at the top of Search whenever there's a
/// query: while typing, after the Search key (keyboard gone), after scrolling, and after coming back from a pushed
/// page; the chosen one is kept. Against the local dev stack: `MAGPIE_IT=1 scripts/test-app.sh`. Guard G0: localhost
/// only.
final class SearchScopesUITests: XCTestCase {
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
    @MainActor private func openSearch() throws -> (XCUIApplication, XCUIElement) {
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
        let field = app.searchFields.firstMatch
        for _ in 0..<3 where !field.exists {
            app.tabBars.buttons["Search"].tap()
            _ = field.waitForExistence(timeout: 5)
        }
        XCTAssertTrue(field.exists, "search field not found")
        return (app, field)
    }


    /// The four choices, each on screen and tappable.
    @MainActor private func assertChoices(_ app: XCUIApplication, _ moment: String,
                                          file: StaticString = #filePath, line: UInt = #line) {
        for name in ["All", "Songs", "Artists", "Albums"] {
            let choice = app.buttons[name].firstMatch
            XCTAssertTrue(choice.waitForExistence(timeout: 5), "\"\(name)\" is gone \(moment)", file: file, line: line)
            XCTAssertTrue(choice.isHittable, "\"\(name)\" can't be tapped \(moment)", file: file, line: line)
        }
    }

    @MainActor func testChoicesStayWheneverThereIsAQuery() throws {
        let (app, field) = try openSearch()
        field.tap()
        field.typeText("aurora")
        XCTAssertTrue(app.buttons["search-song-0"].waitForExistence(timeout: 15), "no results for aurora")
        assertChoices(app, "while typing")

        // The Search key: the keyboard goes, the choices stay.
        field.typeText("\n")
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5), "the keyboard stayed up")
        assertChoices(app, "after the Search key")

        // A choice made now narrows the results.
        app.buttons["Albums"].firstMatch.tap()
        let album = app.buttons["search-album-0"]
        XCTAssertTrue(album.waitForExistence(timeout: 10), "no albums for aurora")
        XCTAssertFalse(app.buttons["search-song-0"].exists, "Albums still lists songs")
        XCTAssertTrue(app.buttons["Albums"].firstMatch.isSelected, "Albums is not the chosen one")

        app.swipeUp()
        app.swipeDown()
        assertChoices(app, "after scrolling")

        // A pushed page and back: the choice is kept.
        album.tap()
        let back = app.navigationBars.buttons.firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 10), "the album page did not open")
        XCTAssertTrue(app.buttons["search-album-0"].waitForNonExistence(timeout: 5), "the album page did not open")
        back.tap()
        XCTAssertTrue(app.buttons["search-album-0"].waitForExistence(timeout: 10), "did not come back to Search")
        assertChoices(app, "after coming back from a page")
        XCTAssertTrue(app.buttons["Albums"].firstMatch.isSelected, "the choice was not kept")
        XCTAssertFalse(app.buttons["search-song-0"].exists, "the choice was not kept")

        // Another tab and back (while searching, the tab bar is folded to Home beside the field).
        app.tabBars.buttons["Home"].tap()
        XCTAssertTrue(app.buttons["search-album-0"].waitForNonExistence(timeout: 5), "Home did not open")
        app.tabBars.buttons["Search"].tap()
        XCTAssertTrue(app.buttons["search-album-0"].waitForExistence(timeout: 10), "did not come back to Search")
        assertChoices(app, "after another tab and back")

        // The search closed, then a recent search: results with the search no longer presented. The system scope bar
        // went with the presentation, so here the choices were gone (round 23, the owner's report).
        let close = app.buttons["Close"].exists ? app.buttons["Close"] : app.buttons["Cancel"]
        close.firstMatch.tap()
        XCTAssertTrue(app.buttons["search-album-0"].waitForNonExistence(timeout: 5), "closing kept the results")
        XCTAssertFalse(app.buttons["Albums"].exists, "choices with no query")
        let recent = app.buttons["aurora"].firstMatch
        XCTAssertTrue(recent.waitForExistence(timeout: 5), "aurora is not a recent search")
        recent.tap()
        XCTAssertTrue(app.buttons["search-album-0"].waitForExistence(timeout: 15), "no results for the recent search")
        assertChoices(app, "after a recent search")
        XCTAssertTrue(app.buttons["Albums"].firstMatch.isSelected, "the choice was not kept")
        app.buttons["Songs"].firstMatch.tap()
        XCTAssertTrue(app.buttons["search-song-0"].waitForExistence(timeout: 10), "Songs did not list songs")
        XCTAssertFalse(app.buttons["search-album-0"].exists, "Songs still lists albums")
    }
}
