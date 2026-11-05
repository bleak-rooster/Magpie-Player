import XCTest

/// Round 15 C4 (owner, build 15): Home › Recommended's circles show pictures, as Library › Recommended's do; and a
/// genre group's albums can be sorted and narrowed to a sub-genre. Run in Release (what TestFlight ships) against the
/// dev Navidrome and the localhost stub Aurral (`MAGPIE_IT=1`). Guard G0: localhost only.
///
/// The stub's recommendations carry no picture (as Aurral's usually don't) and the localhost stack has no public picture
/// host for the artist page's picture, so the test launches with `-MagpieUITestArtistPicture <MBID>`: the app puts a
/// plain picture for that artist in its outside-art folder, as if the artist page's picture had loaded before. Build 15's
/// Home tile never looked there (it asked only for a picture the server named); now it must show it.
final class C4HomeGenresUITests: XCTestCase {
    private struct Stack {
        var url: String
        var user: String
        var password: String
        var aurral: URL
    }

    /// Stub Arrows, the first of the stub's recommended artists.
    private static let stubArrows = "a74b1b7f-71a5-4011-9441-d0b5e4122711"

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

    @MainActor private func signIn(_ app: XCUIApplication, _ s: Stack, aurral: Bool) {
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
        guard aurral else { return }
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

    /// Item 1: under Home's Recommended chip, Stub Arrows' circle shows a picture though the server named none.
    @MainActor func testHomeRecommendedCircleShowsAPicture() throws {
        let s = try stack()
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-MagpieResetState", "YES", "-MagpieUITesting", "YES", "-MagpieNetwork", "wifi",
                               "-MagpieResetLayouts", "YES", "-MagpieUITestArtistPicture", Self.stubArrows]
        app.launch()
        signIn(app, s, aurral: true)
        app.tabBars.buttons["Home"].tap()
        let recommended = app.buttons["home-chip-recommended"]
        XCTAssertTrue(recommended.waitForExistence(timeout: 30), "the Recommended chip")
        recommended.tap()
        XCTAssertTrue(app.staticTexts["Stub Arrows"].waitForExistence(timeout: 15), "Stub Arrows under Recommended")
        let marker = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "home-artist-art-\(Self.stubArrows)")).firstMatch
        XCTAssertTrue(marker.waitForExistence(timeout: 15), "the circle's picture element")
        let loaded = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "artwork-loaded"), object: marker)
        XCTAssertEqual(XCTWaiter().wait(for: [loaded], timeout: 20), .completed,
                       "Home's circle is still the placeholder (\(String(describing: marker.value)))")
    }

    /// The album names in the grid, top first (each tile's label starts with its album's name).
    @MainActor private func albumOrder(_ app: XCUIApplication, count: Int) -> [String] {
        (0..<count).map { app.buttons["album-\($0)"].label }
    }

    @MainActor private func waitForOrder(_ app: XCUIApplication, first: String, _ what: String) {
        let tile = app.buttons["album-0"]
        let starts = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH %@", first), object: tile)
        XCTAssertEqual(XCTWaiter().wait(for: [starts], timeout: 15), .completed,
                       "\(what): the first album is \(tile.exists ? tile.label : "missing")")
    }

    /// Item 2: Library › Genres › Electronic: Name order, then Oldest changes it, then the Electronic chip leaves its one
    /// album, and Clear brings the others back in the kept order. Dev stack (albums whose files are there): Continuum
    /// (Ambient, 2019), Lowlands (Ambient, 2016), Late Night Finds, Vol. 1 (Electronic, 2023).
    @MainActor func testGenreGroupSortAndSubGenreFilter() throws {
        let s = try stack()
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-MagpieResetState", "YES", "-MagpieUITesting", "YES", "-MagpieNetwork", "wifi",
                               "-MagpieResetLayouts", "YES"]
        app.launch()
        signIn(app, s, aurral: false)
        let genres = app.buttons["library-genres"]
        for _ in 0..<3 where !genres.exists {
            app.tabBars.buttons["Library"].tap()
            _ = genres.waitForExistence(timeout: 5)
        }
        genres.tap()
        let group = app.buttons["genre-group-electronic"].firstMatch
        XCTAssertTrue(group.waitForExistence(timeout: 15), "the Electronic group")
        group.tap()

        let sort = app.buttons["genre-sort"]
        XCTAssertTrue(sort.waitForExistence(timeout: 15), "the sort chip")
        XCTAssertTrue(app.staticTexts["genre-album-count"].waitForExistence(timeout: 15), "the album count")
        if !sort.label.contains("Name") {   // a sort kept from an earlier run
            sort.tap()
            app.buttons["Name"].firstMatch.tap()
        }
        waitForOrder(app, first: "Continuum", "Name")
        app.swipeUp()   // the grid sits below the controls
        XCTAssertTrue(app.buttons["album-2"].waitForExistence(timeout: 10),
                      "the group's three albums: \(app.staticTexts.allElementsBoundByIndex.map(\.label))")
        let byName = albumOrder(app, count: 3)
        XCTAssertTrue(byName[1].hasPrefix("Late Night Finds") && byName[2].hasPrefix("Lowlands"), "Name: \(byName)")

        sort.tap()
        let oldest = app.buttons["Oldest"].firstMatch
        XCTAssertTrue(oldest.waitForExistence(timeout: 5), "the sort menu")
        oldest.tap()
        waitForOrder(app, first: "Lowlands", "Oldest")
        let byYear = albumOrder(app, count: 3)
        XCTAssertTrue(byYear[1].hasPrefix("Continuum") && byYear[2].hasPrefix("Late Night Finds"), "Oldest: \(byYear)")
        XCTAssertTrue(sort.label.contains("Oldest"), "the chip shows the sort (\(sort.label))")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "oldest"
        shot.lifetime = .keepAlways
        add(shot)

        let electronic = app.buttons["genre-chip-Electronic"]
        XCTAssertTrue(electronic.waitForExistence(timeout: 5), "the Electronic chip")
        electronic.tap()
        waitForOrder(app, first: "Late Night Finds", "the Electronic chip")
        XCTAssertFalse(app.buttons["album-1"].waitForExistence(timeout: 3), "only Electronic's album")
        let clear = app.buttons["genre-clear"]
        XCTAssertTrue(clear.exists, "Clear shows while a filter is on")
        for _ in 0..<3 where !clear.isHittable { app.swipeDown() }   // back up to the controls
        clear.tap()
        waitForOrder(app, first: "Lowlands", "after Clear the sort stays")
        XCTAssertTrue(app.buttons["album-2"].waitForExistence(timeout: 10), "all three again")

        // Put the kept sort back, so other tests meet the default.
        sort.tap()
        app.buttons["Name"].firstMatch.tap()
        waitForOrder(app, first: "Continuum", "Name again")
    }
}
