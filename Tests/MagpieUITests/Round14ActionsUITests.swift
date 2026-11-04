import XCTest

/// Round 14 A3 fix round 1: a chart song's ⋯ › Save to playlist › Whole artist › New playlist… on the dev stack with the
/// localhost stub Aurral and the dev Lidarr: once the picker has closed, the usual Add (the sheet, or one confirmation
/// with your defaults) appears. It is cancelled: nothing is written to Lidarr. The playlist the test makes on the dev
/// Navidrome is deleted afterwards. Guard G0: localhost only.
/// FX (S14 M2, D116): Whole artist uses the server's linked artist MBID only when the dev Lidarr's lookup names the
/// song's own artist. The stub's links always answer ARTIST_A, which Lidarr names "Radiohead", so the test signs in to
/// the stub's `lidarr-artist` scenario (its chart songs are credited to "Radiohead"); the default scenario's
/// "Stub Arrows" is correctly refused with "Couldn't match this artist".
final class Round14ActionsUITests: XCTestCase {
    private struct Stack {
        var url: String
        var user: String
        var password: String
        var aurral: URL
        var lidarr: String
        var lidarrKey: String
    }

    private func stack() throws -> Stack {
        let env = ProcessInfo.processInfo.environment
        guard env["MAGPIE_IT"] == "1" else { throw XCTSkip("set MAGPIE_IT=1 (MAGPIE_IT=1 scripts/test-app.sh) to run") }
        guard let url = env["MAGPIE_IT_URL"], let user = env["MAGPIE_IT_USER"], let password = env["MAGPIE_IT_PASSWORD"],
              let aurralText = env["MAGPIE_IT_AURRAL_URL"], let aurral = URL(string: aurralText),
              let lidarr = env["MAGPIE_IT_LIDARR_URL"], let key = env["MAGPIE_IT_LIDARR_KEY"],
              !url.isEmpty, !user.isEmpty, !password.isEmpty, !lidarr.isEmpty, !key.isEmpty else {
            XCTFail("MAGPIE_IT=1 but the dev stack, its Lidarr or the stub Aurral wasn't passed in")
            throw XCTSkip("missing dev-stack environment")
        }
        for address in [URLComponents(string: url)?.host, aurral.host(), URLComponents(string: lidarr)?.host] {
            guard let host = address, ["127.0.0.1", "localhost"].contains(host) else {
                XCTFail("Refusing to run against a non-local server; the UI test only talks to the dev stack")
                throw XCTSkip("non-local server")
            }
        }
        return Stack(url: url, user: user, password: password, aurral: aurral, lidarr: lidarr, lidarrKey: key)
    }

    @MainActor private func signIn(_ app: XCUIApplication, _ s: Stack, scenario: String = "default") {
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

        // The stub Aurral.
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

        // The dev Lidarr (reads only: its status and set-up).
        let lidarrRow = app.buttons["settings-lidarr-account"]
        XCTAssertTrue(lidarrRow.waitForExistence(timeout: 10))
        lidarrRow.tap()
        let connect = app.buttons["settings-connect-lidarr"]
        if connect.waitForExistence(timeout: 5) {
            connect.tap()
            let lidarrAddress = app.textFields["lidarr-address"]
            XCTAssertTrue(lidarrAddress.waitForExistence(timeout: 10))
            lidarrAddress.tap()
            lidarrAddress.typeText(s.lidarr)
            let apiKey = app.secureTextFields["lidarr-api-key"]
            apiKey.tap()
            apiKey.typeText(s.lidarrKey)
            app.buttons["lidarr-connect"].tap()
            let version = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Version")).firstMatch
            XCTAssertTrue(version.waitForExistence(timeout: 20), "connected to the dev Lidarr")
            app.buttons["Done"].firstMatch.tap()
        }
        let done = app.buttons["settings-done"]
        for _ in 0..<3 where !done.exists { app.navigationBars.buttons.element(boundBy: 0).tap() }
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        done.tap()
    }

    /// Deletes the dev Navidrome's playlists named `name` (the ones this test made), through the Subsonic API.
    private func deletePlaylists(named name: String, _ s: Stack) {
        func call(_ method: String, _ extra: [URLQueryItem]) -> Data? {
            var c = URLComponents(string: s.url.hasSuffix("/") ? s.url + "rest/\(method)" : s.url + "/rest/\(method)")!
            let hex = s.password.utf8.map { String(format: "%02x", $0) }.joined()
            c.queryItems = [URLQueryItem(name: "u", value: s.user), URLQueryItem(name: "p", value: "enc:" + hex),
                            URLQueryItem(name: "v", value: "1.16.1"), URLQueryItem(name: "c", value: "magpie-uitest"),
                            URLQueryItem(name: "f", value: "json")] + extra
            let done = expectation(description: method)
            var body: Data?
            URLSession.shared.dataTask(with: c.url!) { data, _, _ in body = data; done.fulfill() }.resume()
            wait(for: [done], timeout: 15)
            return body
        }
        guard let data = call("getPlaylists", []),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let response = json["subsonic-response"] as? [String: Any],
              let lists = (response["playlists"] as? [String: Any])?["playlist"] as? [[String: Any]] else { return }
        for list in lists where list["name"] as? String == name {
            if let id = list["id"] as? String { _ = call("deletePlaylist", [URLQueryItem(name: "id", value: id)]) }
        }
    }

    @MainActor func testSaveToPlaylistWholeArtistShowsTheAddAfterThePickerCloses() throws {
        let s = try stack()
        continueAfterFailure = false
        let name = "A3 UI \(UUID().uuidString.prefix(8))"
        addTeardownBlock { [s] in self.deletePlaylists(named: name, s) }
        let app = XCUIApplication()
        app.launchArguments = ["-MagpieResetState", "YES", "-MagpieUITesting", "YES", "-MagpieNetwork", "wifi"]
        app.launch()
        signIn(app, s, scenario: "lidarr-artist")

        app.tabBars.buttons["Library"].tap()
        let trending = app.buttons["library-trending"]
        for _ in 0..<4 where !trending.isHittable { app.swipeUp() }
        XCTAssertTrue(trending.waitForExistence(timeout: 15))
        trending.tap()
        XCTAssertTrue(app.descendants(matching: .any)["trending-song-0"].waitForExistence(timeout: 20))

        // A chart song's ⋯ (shown only with Lidarr).
        let menu = app.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@", "preview-row-menu", "More")).firstMatch
        for _ in 0..<3 where !menu.isHittable { app.swipeUp() }
        XCTAssertTrue(menu.waitForExistence(timeout: 10), "the outside song's menu")
        menu.tap()
        let save = app.buttons["Save to playlist"].firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        save.tap()
        let whole = app.buttons["Whole artist"].firstMatch
        XCTAssertTrue(whole.waitForExistence(timeout: 5))
        whole.tap()

        // The picker: New playlist…
        let newPlaylist = app.buttons["save-new-playlist"]
        XCTAssertTrue(newPlaylist.waitForExistence(timeout: 10))
        newPlaylist.tap()
        let field = app.textFields["Name"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(name)
        app.alerts.buttons["Create"].tap()

        // Once the picker has closed: the usual Add (the sheet, or one confirmation with your defaults).
        let sheetCancel = app.buttons["add-cancel"]
        let confirm = app.buttons["add-confirm"]
        let unmatched = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "match this artist")).firstMatch
        let appeared = NSPredicate { _, _ in sheetCancel.exists || confirm.exists || unmatched.exists }
        wait(for: [XCTNSPredicateExpectation(predicate: appeared, object: nil)], timeout: 20)
        XCTAssertFalse(unmatched.exists, "Lidarr names the linked artist as the song's own (D116), so it matches")
        XCTAssertFalse(app.buttons["save-new-playlist"].exists, "the picker has closed")
        attachScreenshot(app, "whole-artist-add")
        if sheetCancel.exists { sheetCancel.tap() } else { app.alerts.buttons["Cancel"].firstMatch.tap() }   // nothing written
    }

    @MainActor private func attachScreenshot(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
