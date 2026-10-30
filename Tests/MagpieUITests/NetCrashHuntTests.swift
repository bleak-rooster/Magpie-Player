import XCTest

/// Streaming crash hunt (owner report, builds 3/4: "randomly crashes while a song buffers on a weak connection").
/// Plays through `dev/netem/badnet.py`, a local proxy in front of the dev Navidrome, and walks it through every fault
/// (stall, drip, drop, reset, 5xx on retry, slow headers, flapping, random chaos) on Original, AAC and Opus, with
/// skips, seeks, pause/resume and the Queue sheet. Runs only when `MAGPIE_NETEM_CONTROL` (the proxy's control
/// file) and `MAGPIE_IT_URL` (the proxy's 127.0.0.1 address) are passed in; see the net-crash report.
final class NetCrashHuntTests: XCTestCase {
    private var control: String!

    private func setFault(_ json: String) {
        try? json.write(toFile: control, atomically: true, encoding: .utf8)
    }

    @MainActor private func launchSignedIn() throws -> XCUIApplication {
        let env = ProcessInfo.processInfo.environment
        guard let control = env["MAGPIE_NETEM_CONTROL"], !control.isEmpty,
              let url = env["MAGPIE_IT_URL"], let user = env["MAGPIE_IT_USER"], let password = env["MAGPIE_IT_PASSWORD"]
        else { throw XCTSkip("set MAGPIE_NETEM_CONTROL and MAGPIE_IT_* to run the streaming crash hunt") }
        guard let host = URLComponents(string: url)?.host, ["127.0.0.1", "localhost"].contains(host) else {
            XCTFail("Refusing a non-local server (\(url))")
            throw XCTSkip("non-local server")
        }
        self.control = control
        setFault(#"{"mode":"good"}"#)
        continueAfterFailure = true
        let app = XCUIApplication()
        app.launchArguments = ["-MagpieResetState", "YES", "-MagpieUITesting", "YES", "-MagpieNetwork", "wifi"]
        app.launch()
        let address = app.textFields["connect-address-0"]
        XCTAssertTrue(address.waitForExistence(timeout: 10))
        address.tap()
        address.typeText(url)
        app.textFields["connect-username"].tap()
        app.textFields["connect-username"].typeText(user)
        app.secureTextFields["connect-password"].tap()
        app.secureTextFields["connect-password"].typeText(password)
        app.buttons["connect-continue"].tap()
        let notNow = app.buttons["Not Now"]
        if notNow.waitForExistence(timeout: 5) {
            for _ in 0..<3 where notNow.exists {
                notNow.tap()
                _ = notNow.waitForNonExistence(timeout: 2)
            }
        }
        XCTAssertTrue(app.tabBars.buttons["Library"].waitForExistence(timeout: 20))
        return app
    }

    @MainActor private func openNowPlaying(_ app: XCUIApplication, album: Int) -> XCUIElement {
        let albums = app.buttons["library-albums"]
        for _ in 0..<3 where !albums.exists {
            app.tabBars.buttons["Library"].tap()
            _ = albums.waitForExistence(timeout: 5)
        }
        albums.tap()
        let albumButton = app.buttons["album-\(album)"]
        XCTAssertTrue(albumButton.waitForExistence(timeout: 15))
        albumButton.tap()
        let firstTrack = app.buttons["track-0"]
        XCTAssertTrue(firstTrack.waitForExistence(timeout: 15))
        firstTrack.tap()
        let mini = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Now playing:")).firstMatch
        XCTAssertTrue(mini.waitForExistence(timeout: 30))
        for _ in 0..<3 where !app.buttons["np-play-pause"].exists {
            mini.tap()
            _ = app.buttons["np-play-pause"].waitForExistence(timeout: 5)
        }
        return app.otherElements["now-playing"]
    }

    @MainActor private func alive(_ app: XCUIApplication, _ what: String) -> Bool {
        let ok = app.state == .runningForeground
        XCTAssertTrue(ok, "the app quit: \(what)")
        return ok
    }

    @MainActor func testStreamingUnderBadNetwork() throws {
        let app = try launchSignedIn()
        let env = ProcessInfo.processInfo.environment
        let nowPlaying = openNowPlaying(app, album: Int(env["MAGPIE_NETEM_ALBUM"] ?? "0") ?? 0)
        let formats = (env["MAGPIE_NETEM_FORMATS"] ?? "raw,aac,opus").split(separator: ",").map(String.init)
        let faults = [
            #""mode":"stall","after":65536,"secs":12"#,
            #""mode":"drip","rate":4096"#,
            #""mode":"drop","after":65536"#,
            #""mode":"reset","after":32768"#,
            #""mode":"5xx","status":503"#,
            #""mode":"5xx-all","status":503"#,
            #""mode":"hdelay","secs":10"#,
            #""mode":"flap","period":5,"bad":{"mode":"stall","after":16384,"secs":8}"#,
            #""mode":"chaos","seed":1"#,
            #""mode":"chaos","seed":2"#,
        ]
        let rounds = Int(env["MAGPIE_NETEM_ROUNDS"] ?? "1") ?? 1
        for round in 0..<rounds {
            for format in formats {
                for (i, fault) in faults.enumerated() {
                    let tag = "round \(round) \(format) fault \(i) {\(fault)}"
                    setFault(#"{"format":"\#(format)",\#(fault)}"#)
                    // Let it buffer and stall, then do things while it does.
                    Thread.sleep(forTimeInterval: 4)
                    guard alive(app, "\(tag), playing") else { return }
                    switch i % 5 {
                    case 0:
                        let next = nowPlaying.buttons["Next"]
                        if next.exists { next.tap() }
                    case 1:
                        let slider = nowPlaying.sliders.firstMatch
                        if slider.exists { slider.adjust(toNormalizedSliderPosition: 0.85) }
                    case 2:
                        let pp = app.buttons["np-play-pause"]
                        if pp.exists { pp.tap(); Thread.sleep(forTimeInterval: 2); pp.tap() }
                    case 3:
                        let queue = nowPlaying.buttons["Queue"]
                        if queue.exists {
                            queue.tap()
                            Thread.sleep(forTimeInterval: 5)
                            if app.navigationBars["Queue"].exists { app.navigationBars["Queue"].swipeDown(velocity: .fast) }
                        }
                    default:
                        let next = nowPlaying.buttons["Next"]
                        if next.exists { next.tap(); next.tap() }
                    }
                    guard alive(app, "\(tag), after action") else { return }
                    Thread.sleep(forTimeInterval: 8)
                    guard alive(app, "\(tag), after wait") else { return }
                    // A halted song (failed) needs a play to carry on.
                    let pp = app.buttons["np-play-pause"]
                    if pp.exists, pp.label == "Play" { pp.tap() }
                }
            }
        }
        setFault(#"{"mode":"good"}"#)
        Thread.sleep(forTimeInterval: 5)
        _ = alive(app, "the end")
    }
}
