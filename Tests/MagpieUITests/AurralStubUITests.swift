import XCTest

/// Round 14 A1 fix round 1: a smoke test that the app reaches the localhost stub Aurral (`dev/aurral-stub`, started by
/// `MAGPIE_IT=1 scripts/test-app.sh`): Settings › Aurral signs in, and the app reads the 2.13 bootstrap. The stub's
/// request log (read by this test runner, never by the app) shows what the app asked. A scenario is chosen by the
/// address (`<stub>/s/<scenario>`). Trending's decoding over the network is `MagpieTests/AurralStubServerTests` (no
/// screen shows it yet). Guard G0: the dev stack and the stub on localhost only.
final class AurralStubUITests: XCTestCase {
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

    /// The stub's request log ("METHOD /path"), read by the test runner.
    private func stubLog(_ root: URL) throws -> [String] {
        let data = try Data(contentsOf: root.appending(path: "__stub/log"))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return object?["requests"] as? [String] ?? []
    }

    @MainActor func testSignsInToTheStubAurralAndReadsTheBootstrap() throws {
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
        XCTAssertFalse(app.descendants(matching: .any)["aurral-error"].exists)

        let log = try stubLog(s.aurral)
        XCTAssertTrue(log.contains("POST /api/auth/login"), "\(log)")
        XCTAssertTrue(log.contains("GET /api/health/bootstrap"), "the app read the 2.13 bootstrap: \(log)")
        XCTAssertTrue(log.contains("GET /api/playlists/status"), "\(log)")
    }
}
