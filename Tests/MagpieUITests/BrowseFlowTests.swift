import XCTest

/// Signs in to the local dev stack, opens the first album and plays its first track.
/// Runs only with `MAGPIE_IT=1 scripts/test-app.sh`, which passes the dev-stack address and
/// credentials from `dev/.env.local` as TEST_RUNNER_ variables. Guard G0: localhost only.
final class BrowseFlowTests: XCTestCase {
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

    /// Launches signed out, signs in to the dev stack and waits for the tab bar.
    @MainActor private func launchSignedIn() throws -> XCUIApplication {
        let stack = try devStack()
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-MagpieResetState", "YES"]
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
        if notNow.waitForExistence(timeout: 3) { notNow.tap() }
        XCTAssertTrue(app.tabBars.buttons["Library"].waitForExistence(timeout: 20),
                      "did not reach the tabs; error: \(errorText(app))")
        return app
    }

    @MainActor func testSignInBrowsePlay() throws {
        let app = try launchSignedIn()
        let library = app.tabBars.buttons["Library"]
        // Library › Albums › first album. The tab bar can swallow a tap while it settles; tap again if so.
        let albums = app.buttons["library-albums"]
        for _ in 0..<3 where !albums.exists {
            library.tap()
            _ = albums.waitForExistence(timeout: 5)
        }
        albums.tap()
        let firstAlbum = app.buttons["album-0"]
        XCTAssertTrue(firstAlbum.waitForExistence(timeout: 15))
        firstAlbum.tap()

        // First track: remember its title, play it
        let firstTrack = app.buttons["track-0"]
        XCTAssertTrue(firstTrack.waitForExistence(timeout: 15))
        let title = firstTrack.label
        XCTAssertFalse(title.isEmpty)
        firstTrack.tap()

        // The mini player shows that title.
        let mini = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Now playing: \(title),")).firstMatch
        XCTAssertTrue(mini.waitForExistence(timeout: 15), "mini player did not show \(title)")
    }

    /// Search tab: type a name from the dev library, tap the first song, see it in the mini player.
    @MainActor func testSearchAndPlay() throws {
        let app = try launchSignedIn()
        // The tab bar can swallow a tap while it settles; tap again if so.
        let field = app.searchFields.firstMatch
        for _ in 0..<3 where !field.exists {
            app.tabBars.buttons["Search"].tap()
            _ = field.waitForExistence(timeout: 5)
        }
        XCTAssertTrue(field.exists, "search field not found")
        field.tap()
        field.typeText("Paper Planes")
        let song = app.buttons["search-song-0"]
        XCTAssertTrue(song.waitForExistence(timeout: 15), "no song result for the dev library's Paper Planes")
        let title = song.label.components(separatedBy: ", ").first ?? song.label
        song.tap()
        let mini = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Now playing: \(title),")).firstMatch
        XCTAssertTrue(mini.waitForExistence(timeout: 15), "mini player did not show \(title)")
    }

    @MainActor private func errorText(_ app: XCUIApplication) -> String {
        let error = app.staticTexts["connect-error"]
        return error.exists ? error.label : "none"
    }
}
