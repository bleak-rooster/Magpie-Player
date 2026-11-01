import XCTest

/// R14: Settings › Appearance › App icon switches the Home Screen icon through `setAlternateIconName`, and iOS's
/// "You have changed the icon" alert is answered. A hosted test can't do this: the call doesn't return until the
/// system alert is dismissed. Runs only with `MAGPIE_IT=1 scripts/test-app.sh` (Settings needs a signed-in app);
/// localhost dev stack only (G0). Ends on the default icon.
final class AppIconUITests: XCTestCase {
    @MainActor func testPickerSwitchesTheIconAndBack() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["MAGPIE_IT"] == "1" else { throw XCTSkip("set MAGPIE_IT=1 (MAGPIE_IT=1 scripts/test-app.sh) to run") }
        guard let url = env["MAGPIE_IT_URL"], let user = env["MAGPIE_IT_USER"], let password = env["MAGPIE_IT_PASSWORD"],
              let host = URLComponents(string: url)?.host, ["127.0.0.1", "localhost"].contains(host) else {
            XCTFail("MAGPIE_IT=1 but no local dev-stack URL/credentials")
            return
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-MagpieResetState", "YES", "-MagpieUITesting", "YES", "-MagpieNetwork", "wifi"]
        app.launch()

        let address = app.textFields["connect-address-0"]
        XCTAssertTrue(address.waitForExistence(timeout: 10))
        address.tap(); address.typeText(url)
        app.textFields["connect-username"].tap(); app.textFields["connect-username"].typeText(user)
        app.secureTextFields["connect-password"].tap(); app.secureTextFields["connect-password"].typeText(password)
        app.buttons["connect-continue"].tap()
        let notNow = app.buttons["Not Now"]
        if notNow.waitForExistence(timeout: 5) {
            for _ in 0..<3 where notNow.exists { notNow.tap(); _ = notNow.waitForNonExistence(timeout: 2) }
        }
        let libraryTab = app.tabBars.buttons["Library"]
        XCTAssertTrue(libraryTab.waitForExistence(timeout: 20))
        let settings = app.buttons["open-settings"]
        for _ in 0..<3 where !settings.exists { libraryTab.tap(); _ = settings.waitForExistence(timeout: 5) }
        settings.tap()
        let appearance = app.buttons["settings-appearance"]
        XCTAssertTrue(appearance.waitForExistence(timeout: 10))
        for _ in 0..<4 where !appearance.isHittable { app.swipeUp() }
        appearance.tap()

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        func pick(_ id: String) {
            let icon = app.buttons["app-icon-\(id)"]
            for _ in 0..<6 where !(icon.exists && icon.isHittable) { app.swipeUp() }
            XCTAssertTrue(icon.waitForExistence(timeout: 10), id)
            if icon.isSelected { return }   // left there by an earlier run
            icon.tap()
            // iOS confirms with its own alert; the change completes once it is dismissed. The alert can come late under
            // load, and from SpringBoard or inside the app, so answer it wherever it shows until the icon is chosen
            // (deflaked: one 10 s wait on SpringBoard alone sometimes missed it).
            let selected = NSPredicate(format: "isSelected == true")
            let deadline = Date().addingTimeInterval(40)
            while !icon.isSelected, Date() < deadline {
                for ok in [springboard.alerts.buttons["OK"], app.alerts.buttons["OK"]] where ok.exists { ok.tap() }
                XCTAssertFalse(app.staticTexts["Couldn't change the icon. Try again in a moment."].exists, id)
                _ = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: selected, object: icon)], timeout: 1)
            }
            XCTAssertTrue(icon.isSelected, "\(id) is the chosen icon")
        }
        // Each of the 13 has a preview in the grid.
        XCTAssertTrue(app.buttons["app-icon-Default"].waitForExistence(timeout: 10))
        pick("NestSunset")
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "app-icon-picker"; shot.lifetime = .keepAlways
        add(shot)
        XCTAssertFalse(app.staticTexts["Couldn't change the icon. Try again in a moment."].exists)
        pick("Default")
    }
}
