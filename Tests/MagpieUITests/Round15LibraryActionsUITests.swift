import XCTest

/// Round 15 C3 (owner item 6, D139): a Trending song's ⋯ menu offers Try and Add to library, in Release
/// (TestFlight-equivalent), on the dev stack with the localhost stub Aurral and the dev Lidarr. "Allow Magpie to change
/// Lidarr" is off on a fresh install, so each action shows and, tapped, says why: nothing is read from MusicBrainz and
/// nothing is written to Lidarr. Guard G0: localhost only.
final class Round15LibraryActionsUITests: XCTestCase {
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

    @MainActor func testATrendingSongOffersTryAndAddToLibraryAndSaysWhyWithChangesOff() throws {
        let s = try stack()
        continueAfterFailure = false
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

        let menu = app.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@", "preview-row-menu", "More")).firstMatch
        for _ in 0..<3 where !menu.isHittable { app.swipeUp() }
        XCTAssertTrue(menu.waitForExistence(timeout: 10), "the outside song's menu")
        menu.tap()
        let tryIt = app.buttons["song-menu-try"].firstMatch
        let add = app.buttons["song-menu-add-library"].firstMatch
        XCTAssertTrue(tryIt.waitForExistence(timeout: 5), "Try")
        XCTAssertTrue(add.exists, "Add to library")
        attachScreenshot(app, "trending-song-menu")
        add.tap()
        let notice = app.descendants(matching: .any).matching(identifier: "library-notice").firstMatch
        XCTAssertTrue(notice.waitForExistence(timeout: 10), "a tap says why")
        XCTAssertTrue(notice.label.contains("switched off"), notice.label)

        _ = notice.waitForNonExistence(timeout: 8)
        menu.tap()
        XCTAssertTrue(tryIt.waitForExistence(timeout: 5))
        tryIt.tap()
        XCTAssertTrue(notice.waitForExistence(timeout: 10), "Try says why too")
        XCTAssertTrue(notice.label.contains("switched off"), notice.label)
        attachScreenshot(app, "try-explained")
    }

    @MainActor private func attachScreenshot(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
