import XCTest

/// Round 15 C1 (owner items 3 and 4): Top songs from the server show their covers, and a 30-second preview shows its
/// row's cover in the mini player. Run in Release (what TestFlight ships) against the dev Navidrome and the localhost
/// stub Aurral (`MAGPIE_IT=1`, scenario `playable-clip` so the preview really plays and the mini player stays up).
///
/// It uses a library artist's page (Aurora Field) rather than an outside one opened from Recommended: both show the
/// same `TopSongsSection` rows, but the outside page also reads MusicBrainz, which would leave the localhost stack.
/// The covers the stub names come back through its image proxy, as on the owner's server. Guard G0: localhost only.
final class C1PicturesUITests: XCTestCase {
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
        aurralAddress.typeText(s.aurral.appending(path: "s/playable-clip").absoluteString)
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

    /// Waits until the test-only marker labelled `name` says the real picture shows.
    @MainActor private func expectLoaded(_ app: XCUIApplication, _ name: String, _ what: String) {
        let marker = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", name)).firstMatch
        XCTAssertTrue(marker.waitForExistence(timeout: 20), "\(what): no picture element")
        let loaded = NSPredicate(format: "value == %@", "artwork-loaded")
        let wait = XCTNSPredicateExpectation(predicate: loaded, object: marker)
        XCTAssertEqual(XCTWaiter().wait(for: [wait], timeout: 20), .completed,
                       "\(what): still the placeholder (\(String(describing: marker.value)))")
    }

    @MainActor func testTopSongsAndThePreviewMiniPlayerShowCovers() throws {
        let s = try stack()
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-MagpieResetState", "YES", "-MagpieUITesting", "YES", "-MagpieNetwork", "wifi"]
        app.launch()
        signIn(app, s)

        let library = app.tabBars.buttons["Library"]
        let artists = app.buttons["library-artists"]
        for _ in 0..<3 where !artists.exists {
            library.tap()
            _ = artists.waitForExistence(timeout: 5)
        }
        artists.tap()
        let aurora = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Aurora Field'")).firstMatch
        XCTAssertTrue(aurora.waitForExistence(timeout: 15))
        aurora.tap()

        // Owner item 3: the server's top songs, each with its cover.
        let heading = app.staticTexts["Top songs"]
        XCTAssertTrue(heading.waitForExistence(timeout: 20), "Top songs from the server")
        for _ in 0..<3 where !heading.isHittable { app.swipeUp() }
        expectLoaded(app, "top-song-art-0", "Top songs row 1")
        expectLoaded(app, "top-song-art-1", "Top songs row 2")
        expectLoaded(app, "top-song-art-2", "Top songs row 3")

        // Owner item 4: a preview, with its cover in the mini player.
        let play = app.buttons["Play preview"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 10), "the row's preview button")
        play.tap()
        XCTAssertTrue(app.descendants(matching: .any)["preview-mini-player"].waitForExistence(timeout: 15), "the preview plays")
        expectLoaded(app, "preview-mini-player-art", "the preview mini player")
        let stop = app.buttons["Stop preview"].firstMatch
        if stop.exists { stop.tap() }
    }
}
