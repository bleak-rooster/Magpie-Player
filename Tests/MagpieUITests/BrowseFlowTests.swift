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

        // iOS offers to save the password 1-3 s after Continue. The button exists while the prompt is still
        // sliding in, and a tap then can be lost; a prompt left up swallows the next tap outside it (that tap
        // only dismisses it). Tap until it is gone.
        let notNow = app.buttons["Not Now"]
        if notNow.waitForExistence(timeout: 5) {
            for _ in 0..<3 where notNow.exists {
                notNow.tap()
                _ = notNow.waitForNonExistence(timeout: 2)
            }
        }
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

    /// Home › Finish setting up › connect the dev stack's Lidarr: the read-only summary appears
    /// (version, sign-in, root folders, ...). Disconnects again so the next run starts clean.
    @MainActor func testConnectLidarrShowsSummary() throws {
        let env = ProcessInfo.processInfo.environment
        guard let lidarrURL = env["MAGPIE_IT_LIDARR_URL"], let key = env["MAGPIE_IT_LIDARR_KEY"],
              !lidarrURL.isEmpty, !key.isEmpty else { throw XCTSkip("no dev-stack Lidarr passed in") }
        guard let host = URLComponents(string: lidarrURL)?.host, ["127.0.0.1", "localhost"].contains(host) else {
            XCTFail("Refusing a non-local Lidarr (\(lidarrURL))")
            return
        }
        let app = try launchSignedIn()
        let card = app.buttons["finish-setting-up"]
        for _ in 0..<3 where !card.exists {
            app.tabBars.buttons["Home"].tap()
            _ = card.waitForExistence(timeout: 5)
        }
        card.tap()
        let address = app.textFields["lidarr-address"]
        XCTAssertTrue(address.waitForExistence(timeout: 10))
        address.tap()
        address.typeText(lidarrURL)
        let apiKey = app.secureTextFields["lidarr-api-key"]
        apiKey.tap()
        apiKey.typeText(key)
        app.buttons["lidarr-connect"].tap()

        func labelled(_ prefix: String) -> XCUIElement {
            app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
        }
        let error = app.staticTexts["lidarr-error"]
        XCTAssertTrue(labelled("Version").waitForExistence(timeout: 20),
                      "did not connect to the dev Lidarr; error: \(error.exists ? error.label : "none")")
        XCTAssertTrue(labelled("Root folders").exists)
        XCTAssertTrue(labelled("Recycle bin").exists)
        // The form is lazy: scroll to the bottom for Disconnect.
        let disconnect = app.buttons["Disconnect Lidarr"]
        for _ in 0..<6 where !disconnect.exists { app.swipeUp() }
        disconnect.tap()
        XCTAssertTrue(app.textFields["lidarr-address"].waitForExistence(timeout: 10))
    }

    /// Library › Settings with the dev Lidarr connected: the G1 switch (off), set-up, change log and Count
    /// plays are there; Library has a Requests row. Reads only: nothing is switched on.
    @MainActor func testSettingsShowLidarrControlsAndRequests() throws {
        let env = ProcessInfo.processInfo.environment
        guard let lidarrURL = env["MAGPIE_IT_LIDARR_URL"], let key = env["MAGPIE_IT_LIDARR_KEY"],
              !lidarrURL.isEmpty, !key.isEmpty else { throw XCTSkip("no dev-stack Lidarr passed in") }
        guard let host = URLComponents(string: lidarrURL)?.host, ["127.0.0.1", "localhost"].contains(host) else {
            XCTFail("Refusing a non-local Lidarr (\(lidarrURL))")
            return
        }
        let app = try launchSignedIn()
        let libraryTab = app.tabBars.buttons["Library"]
        let settings = app.buttons["open-settings"]
        for _ in 0..<3 where !settings.exists {
            libraryTab.tap()
            _ = settings.waitForExistence(timeout: 5)
        }
        XCTAssertTrue(app.buttons["library-requests"].exists)
        settings.tap()

        let connect = app.buttons["settings-connect-lidarr"]
        XCTAssertTrue(connect.waitForExistence(timeout: 10))
        connect.tap()
        let address = app.textFields["lidarr-address"]
        XCTAssertTrue(address.waitForExistence(timeout: 10))
        address.tap()
        address.typeText(lidarrURL)
        let apiKey = app.secureTextFields["lidarr-api-key"]
        apiKey.tap()
        apiKey.typeText(key)
        app.buttons["lidarr-connect"].tap()
        let version = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Version")).firstMatch
        XCTAssertTrue(version.waitForExistence(timeout: 20))
        app.buttons["Done"].firstMatch.tap()

        let toggle = app.switches["settings-allow-changes"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        XCTAssertEqual(toggle.value as? String, "0", "G1: changes are off until the owner turns them on")
        XCTAssertTrue(app.buttons["settings-provision"].exists)
        XCTAssertFalse(app.buttons["settings-provision"].isEnabled, "set-up needs changes allowed")
        let log = app.buttons["settings-change-log"]
        for _ in 0..<4 where !log.isHittable { app.swipeUp() }
        log.tap()
        XCTAssertTrue(app.navigationBars["Lidarr change log"].waitForExistence(timeout: 10))
        app.navigationBars.buttons.firstMatch.tap()
        let countPlays = app.switches["settings-count-plays"]
        for _ in 0..<4 where !countPlays.isHittable { app.swipeUp() }
        XCTAssertTrue(countPlays.exists)
    }

    @MainActor private func errorText(_ app: XCUIApplication) -> String {
        let error = app.staticTexts["connect-error"]
        return error.exists ? error.label : "none"
    }
}
