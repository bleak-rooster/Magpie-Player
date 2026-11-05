import XCTest

/// Round 15 C2 (owner items 5 and 5b, D130–D134), the Release (TestFlight-equivalent) check: on Trending, pick
/// Worldwide and make it the default; after a relaunch Trending opens on Worldwide; Create flow… with Songs: 10; Edit
/// flow shows 10; change it to 5 and the playlist on the server holds 5. Dev stack and the localhost stub Aurral only
/// (guard G0); the stub's own control route (`/__stub/shared`) says what the playlist holds.
final class ChartFlowUITests: XCTestCase {
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

    /// The stub's own playlists ("name" → song count), read by the test runner from the stub's control route.
    private func sharedPlaylists(_ root: URL) throws -> [String: Int] {
        let data = try Data(contentsOf: root.appending(path: "__stub/shared"))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let list = object?["playlists"] as? [[String: Any]] ?? []
        return Dictionary(list.compactMap { p in (p["name"] as? String).map { ($0, p["trackCount"] as? Int ?? -1) } },
                          uniquingKeysWith: { a, _ in a })
    }

    private func resetStub(_ root: URL) {
        var request = URLRequest(url: root.appending(path: "__stub/reset"))
        // G1 allowlist: stub reset (the localhost stub's own control route, checked local by stack(); never the app's)
        request.httpMethod = "POST"
        let done = expectation(description: "stub reset")
        URLSession.shared.dataTask(with: request) { _, _, _ in done.fulfill() }.resume()
        wait(for: [done], timeout: 10)
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
        aurralAddress.typeText(s.aurral.appending(path: "s/default").absoluteString)
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

    @MainActor private func openTrending(_ app: XCUIApplication) {
        let library = app.tabBars.buttons["Library"]
        XCTAssertTrue(library.waitForExistence(timeout: 20))
        library.tap()
        let row = app.buttons["library-trending"]
        for _ in 0..<4 where !row.isHittable { app.swipeUp() }
        XCTAssertTrue(row.waitForExistence(timeout: 20), "Library › Trending")
        row.tap()
        XCTAssertTrue(app.buttons["trending-chart-picker"].waitForExistence(timeout: 20), "Trending's chart button")
    }

    @MainActor private func element(_ app: XCUIApplication, _ id: String, timeout: TimeInterval = 20) -> XCUIElement {
        let e = app.descendants(matching: .any)[id]
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !(e.exists && e.isHittable) {
            if e.exists { app.swipeUp() } else { _ = e.waitForExistence(timeout: 1) }
        }
        return e
    }

    private func waitForShared(_ root: URL, name: String, count: Int, timeout: TimeInterval = 20) throws -> Int? {
        let deadline = Date().addingTimeInterval(timeout)
        var last: Int?
        while Date() < deadline {
            last = try sharedPlaylists(root)[name]
            if last == count { return last }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return last
    }

    @MainActor func testWorldwideAsDefaultThenAFlowOfTenShortenedToFive() throws {
        let s = try stack()
        continueAfterFailure = false
        resetStub(s.aurral)
        let app = XCUIApplication()
        app.launchArguments = ["-MagpieResetState", "YES", "-MagpieUITesting", "YES", "-MagpieNetwork", "wifi",
                               "-MagpieResetLayouts", "YES"]
        app.launch()
        signIn(app, s)
        openTrending(app)

        // Pick Worldwide and make it the default.
        XCTAssertFalse(app.buttons["trending-chart-picker"].label.contains("Worldwide"), "the server's region at first")
        app.buttons["trending-chart-picker"].tap()
        let worldwide = app.buttons["chart-option-worldwide"]
        XCTAssertTrue(worldwide.waitForExistence(timeout: 10))
        worldwide.tap()
        XCTAssertTrue(app.descendants(matching: .any)["trending-song-0"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["World Song 1"].firstMatch.waitForExistence(timeout: 10), "the worldwide chart shows")
        let makeDefault = app.buttons["trending-make-default"]
        XCTAssertTrue(makeDefault.waitForExistence(timeout: 10))
        makeDefault.tap()
        XCTAssertTrue(app.descendants(matching: .any)["trending-default-badge"].waitForExistence(timeout: 20))

        // Relaunch: Trending opens on Worldwide.
        app.terminate()
        let again = XCUIApplication()
        again.launchArguments = ["-MagpieUITesting", "YES", "-MagpieNetwork", "wifi"]
        again.launch()
        openTrending(again)
        let picker = again.buttons["trending-chart-picker"]
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline, !picker.label.contains("Worldwide") { Thread.sleep(forTimeInterval: 0.5) }
        XCTAssertTrue(picker.label.contains("Worldwide"), "opens on the default: \(picker.label)")
        XCTAssertTrue(again.descendants(matching: .any)["trending-default-badge"].waitForExistence(timeout: 10))

        // Create flow… with Songs: 10.
        let create = element(again, "chart-flow-create-open")
        XCTAssertTrue(create.exists, "Create flow…")
        create.tap()
        let ten = again.buttons["chart-flow-preset-10"]
        XCTAssertTrue(ten.waitForExistence(timeout: 10))
        ten.tap()
        XCTAssertTrue(again.staticTexts["Songs: 10"].waitForExistence(timeout: 5))
        again.buttons["chart-flow-create"].tap()
        XCTAssertTrue(again.descendants(matching: .any)["chart-flow-edit"].waitForExistence(timeout: 20), "Edit flow shows")
        XCTAssertEqual(try waitForShared(s.aurral, name: "Top Worldwide", count: 10), 10, "the server's playlist holds 10")

        // Edit flow shows 10; change it to 5.
        element(again, "chart-flow-edit").tap()
        XCTAssertTrue(again.staticTexts["Songs: 10"].waitForExistence(timeout: 10), "Edit flow shows 10")
        let stepper = again.steppers["chart-flow-count"]
        XCTAssertTrue(stepper.waitForExistence(timeout: 5))
        let decrement = stepper.buttons.element(boundBy: 0)
        for _ in 0..<5 { decrement.tap() }
        XCTAssertTrue(again.staticTexts["Songs: 5"].waitForExistence(timeout: 5))
        again.buttons["chart-flow-save"].tap()
        XCTAssertEqual(try waitForShared(s.aurral, name: "Top Worldwide", count: 5), 5, "the playlist has 5")
        XCTAssertTrue(again.descendants(matching: .any)["chart-flow-count-label"].waitForExistence(timeout: 10))
        XCTAssertEqual(again.descendants(matching: .any)["chart-flow-count-label"].label, "Songs: 5")

        // Never the server's name on Trending.
        let labels = (again.staticTexts.allElementsBoundByIndex + again.buttons.allElementsBoundByIndex).map(\.label)
        XCTAssertTrue(labels.allSatisfy { !$0.localizedCaseInsensitiveContains("Aurral") }, "\(labels)")
    }
}
