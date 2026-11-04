import XCTest

/// Round 14 A5 (owner answer 5): with Aurral set up, Search's "Not in your library" band has Aurral's artists, pages
/// with More, and never names the service. Against the dev stack (Navidrome, no Lidarr connected here) and the
/// localhost stub Aurral 2.13 (`dev/aurral-stub`, started by `MAGPIE_IT=1 scripts/test-app.sh`). Guard G0: localhost
/// only.
final class CombinedSearchUITests: XCTestCase {
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

    private func stubLog(_ root: URL) throws -> [String] {
        let data = try Data(contentsOf: root.appending(path: "__stub/log"))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return object?["requests"] as? [String] ?? []
    }

    @MainActor func testAurralArtistsInTheBandPageWithMore() throws {
        let s = try stack()
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-MagpieResetState", "YES", "-MagpieUITesting", "YES", "-MagpieNetwork", "wifi"]
        app.launch()
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

        // Settings › Aurral: sign in to the stub (2.13, search on).
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
        aurralAddress.typeText(s.aurral.appending(path: "s/default").absoluteString)
        app.textFields["aurral-username"].tap()
        app.textFields["aurral-username"].typeText("magpie")
        app.secureTextFields["aurral-password"].tap()
        app.secureTextFields["aurral-password"].typeText("stub-aurral-password")
        app.buttons["aurral-sign-in"].tap()
        if notNow.waitForExistence(timeout: 4) { notNow.tap() }
        XCTAssertTrue(app.descendants(matching: .any)["aurral-user"].waitForExistence(timeout: 20), "signed in to the stub")
        // Back out of Settings.
        let done = app.buttons["settings-done"]
        for _ in 0..<4 where !done.isHittable {
            app.navigationBars.buttons.firstMatch.tap()
            _ = done.waitForExistence(timeout: 2)
        }
        done.tap()

        // Search: a word the dev library doesn't have; Aurral's artists fill the band.
        let field = app.searchFields.firstMatch
        for _ in 0..<4 where !field.exists {
            app.tabBars.buttons["Search"].tap()
            _ = field.waitForExistence(timeout: 5)
        }
        XCTAssertTrue(field.exists, "search field not found")
        field.tap()
        field.typeText("qzxv")
        app.buttons["Artists"].firstMatch.tap()
        let first = app.descendants(matching: .any)["search-notyet-artist-0"]
        XCTAssertTrue(first.waitForExistence(timeout: 20), "no outside artists")
        XCTAssertFalse(app.descendants(matching: .any)["search-notyet-artist-5"].exists, "one page of five first")
        let more = app.buttons["search-notyet-more-artists"]
        if app.keyboards.buttons["search"].exists { app.keyboards.buttons["search"].tap() }
        for _ in 0..<6 where !more.isHittable { app.swipeUp() }
        XCTAssertTrue(more.waitForExistence(timeout: 5), "no More under the artists")
        XCTAssertEqual(more.label, "More artists")
        more.tap()
        let tenth = app.descendants(matching: .any)["search-notyet-artist-9"]
        for _ in 0..<6 where !tenth.waitForExistence(timeout: 2) { app.swipeUp() }
        if !tenth.exists {
            let ids = app.descendants(matching: .any).allElementsBoundByIndex.filter { $0.identifier.hasPrefix("search") }
                .map { "\($0.identifier):\($0.label.prefix(30))" }
            XCTFail("More didn't add the next five; screen: \(ids.joined(separator: " | "))")
        }

        // The service is never named on the Search screen.
        let named = app.descendants(matching: .any).allElementsBoundByIndex.filter { $0.label.contains("Aurral") }
        XCTAssertTrue(named.isEmpty, "Search names the service: \(named.map(\.label))")
        let log = try stubLog(s.aurral)
        XCTAssertTrue(log.contains("GET /api/search"), "\(log)")
    }
}
