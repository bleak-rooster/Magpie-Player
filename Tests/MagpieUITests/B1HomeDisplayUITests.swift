import XCTest

/// B1 (build-14 owner screenshots): Home's chips show what their sections are (Your flows' playlists, Recommended's
/// artists), the library shelves show the server's lists, and Recommended's circles have pictures. Dev stack + the
/// localhost stub Aurral only (guard G0).
final class B1HomeDisplayUITests: XCTestCase {
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
        aurralAddress.typeText(s.aurral.appending(path: "s/default").absoluteString)
        app.textFields["aurral-username"].tap()
        app.textFields["aurral-username"].typeText("magpie")
        app.secureTextFields["aurral-password"].tap()
        app.secureTextFields["aurral-password"].typeText("stub-aurral-password")
        app.buttons["aurral-sign-in"].tap()
        if notNow.waitForExistence(timeout: 4) { notNow.tap() }
        XCTAssertTrue(app.descendants(matching: .any)["aurral-user"].waitForExistence(timeout: 20), "signed in to the stub")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let done = app.buttons["settings-done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        done.tap()
    }

    /// The texts on screen now.
    @MainActor private func texts(_ app: XCUIApplication) -> [String] { app.staticTexts.allElementsBoundByIndex.map(\.label) }

    /// Each chip shows its own sections' tiles: Recommended's artists ("Like …" lines), Your flows' For you playlists
    /// and More playlists for you, the library's albums under Your library; never one section's tiles under another's
    /// title. Then the same after a relaunch from the saved shelves. Build 14's bug showed only in the optimised build:
    /// run this in Release too (B1 report).
    @MainActor func testHomeChipsShowTheirOwnSections() throws {
        let s = try stack()
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-MagpieResetState", "YES", "-MagpieUITesting", "YES", "-MagpieNetwork", "wifi",
                               "-MagpieResetLayouts", "YES"]
        app.launch()
        signIn(app, s)
        app.tabBars.buttons["Home"].tap()
        check(app, label: "first open")
        app.terminate()
        let again = XCUIApplication()
        again.launchArguments = ["-MagpieUITesting", "YES", "-MagpieNetwork", "wifi"]
        again.launch()
        check(again, label: "relaunch")
    }

    /// Library albums on the dev stack.
    private static let libraryAlbums = ["Atlas of Small Hours", "Paper Planes", "Lowlands"]

    @MainActor private func check(_ app: XCUIApplication, label: String) {
        let recommended = app.buttons["home-chip-recommended"]
        XCTAssertTrue(recommended.waitForExistence(timeout: 30), "\(label): the Recommended chip")
        XCTAssertTrue(app.staticTexts["Jump back in"].waitForExistence(timeout: 20), "\(label): Jump back in")
        recommended.tap()
        XCTAssertTrue(app.staticTexts["Recommended for you"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Stub Arrows"].waitForExistence(timeout: 10), "\(label): an artist under Recommended")
        var shown = texts(app)
        XCTAssertTrue(shown.contains { $0.hasPrefix("Like ") || $0.hasPrefix("Via ") }, "\(label): the artists' lines")
        for album in Self.libraryAlbums {
            XCTAssertFalse(shown.contains(album), "\(label): a library album (\(album)) under Recommended: \(shown)")
        }
        app.buttons["home-chip-discover"].tap()
        XCTAssertTrue(app.staticTexts["Your flows"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Indie Pop Picks"].waitForExistence(timeout: 10), "\(label): For you under Your flows")
        XCTAssertTrue(app.staticTexts["More playlists for you"].exists, "\(label): More playlists for you")
        shown = texts(app)
        for album in Self.libraryAlbums {
            XCTAssertFalse(shown.contains(album), "\(label): a library album (\(album)) under Discover: \(shown)")
        }
        app.buttons["home-chip-library"].tap()
        XCTAssertTrue(app.staticTexts["Recently added"].waitForExistence(timeout: 10))
        shown = texts(app)
        XCTAssertTrue(shown.contains("Atlas of Small Hours"), "\(label): the library's albums under Your library")
        XCTAssertFalse(shown.contains("Stub Arrows") || shown.contains("Indie Pop Picks"),
                       "\(label): nothing from Discover or Recommended under Your library: \(shown)")
        app.buttons["home-chip-all"].tap()
    }
}
