import XCTest

/// Crash hunt 3, item 2: a seeded random walk over the app on the dev stack (localhost only, guard G0) — tabs, Library
/// rows, albums, playlists, genres, play, Now Playing (lyrics, sleep timer, queue), Settings pages, the Home and Library
/// editors (toggle, reorder, reset), downloads (start and cancel), search typing, rapid sheet present and dismiss, and
/// back swipes. The test fails if the app stops running; an action that takes over 5 s is recorded as a hang.
///
/// Runs only with `MAGPIE_IT=1` and `MAGPIE_MONKEY=1` (each walk takes 10–20 minutes):
/// `TEST_RUNNER_MAGPIE_MONKEY=1 MAGPIE_IT=1 …`. `MAGPIE_MONKEY_SEED` and `MAGPIE_MONKEY_STEPS` replay a walk. Nothing
/// it taps writes to Lidarr or ListenBrainz: sign out, the Account and Requests pages, Try, Keep and tokens are left out.
final class MonkeyTests: XCTestCase {
    /// Interactions slower than 5 s since the last step was logged.
    private var slow: [Duration] = []
    private struct DevStack { var url: String; var user: String; var password: String }

    private func devStack() throws -> DevStack {
        let env = ProcessInfo.processInfo.environment
        guard env["MAGPIE_IT"] == "1", env["MAGPIE_MONKEY"] == "1" else {
            throw XCTSkip("set MAGPIE_IT=1 and MAGPIE_MONKEY=1 to run the monkey")
        }
        guard let url = env["MAGPIE_IT_URL"], let user = env["MAGPIE_IT_USER"], let password = env["MAGPIE_IT_PASSWORD"],
              let host = URLComponents(string: url)?.host, ["127.0.0.1", "localhost"].contains(host) else {
            XCTFail("the monkey only talks to the local dev stack")
            throw XCTSkip("no local dev stack")
        }
        return DevStack(url: url, user: user, password: password)
    }

    /// SplitMix64, so a walk replays from its seed.
    struct Rng: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    @MainActor private func launchSignedIn(_ extra: [String]) throws -> XCUIApplication {
        let stack = try devStack()
        continueAfterFailure = true
        let app = XCUIApplication()
        app.launchArguments = ["-MagpieResetState", "YES", "-MagpieUITesting", "YES", "-MagpieNetwork", "wifi"] + extra
        app.launch()
        let address = app.textFields["connect-address-0"]
        XCTAssertTrue(address.waitForExistence(timeout: 15))
        address.tap()
        address.typeText(stack.url)
        app.textFields["connect-username"].tap()
        app.textFields["connect-username"].typeText(stack.user)
        app.secureTextFields["connect-password"].tap()
        app.secureTextFields["connect-password"].typeText(stack.password)
        // At accessibility sizes Continue may sit below the keyboard.
        let go = app.buttons["connect-continue"]
        for _ in 0..<4 where !go.isHittable { app.swipeUp() }
        go.tap()
        let notNow = app.buttons["Not Now"]
        if notNow.waitForExistence(timeout: 5) {
            for _ in 0..<3 where notNow.exists {
                notNow.tap()
                _ = notNow.waitForNonExistence(timeout: 2)
            }
        }
        XCTAssertTrue(app.tabBars.buttons["Library"].waitForExistence(timeout: 30), "did not reach the tabs")
        return app
    }

    @MainActor func testMonkeyDefaultTextSize() throws {
        try walk(seed: 0x6D6F_6E6B, extra: [])
    }

    @MainActor func testMonkeyAccessibilityXXXL() throws {
        try walk(seed: 0x6178_7878, extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
    }

    // MARK: - The walk

    private enum Action: String, CaseIterable {
        case tab, libraryRow, openItem, openCell, play, back, edgeSwipe, scroll, dismissSheet
        case nowPlaying, lyrics, sleepTimer, queue, queueControls, playPause
        case settings, settingsPage, settingsToggle, homeEditor, layoutToggle, layoutReorder, layoutReset
        case download, search, rapidSheets, rapidTabs
    }

    /// How often each action is picked (the walk spends most of its time browsing and playing).
    private static let weights: [Action: Int] = [
        .tab: 8, .libraryRow: 8, .openItem: 12, .openCell: 6, .play: 6, .back: 8, .edgeSwipe: 5, .scroll: 6,
        .dismissSheet: 3, .nowPlaying: 5, .lyrics: 3, .sleepTimer: 3, .queue: 4, .queueControls: 3, .playPause: 2,
        .settings: 3, .settingsPage: 4, .settingsToggle: 3, .homeEditor: 3, .layoutToggle: 4, .layoutReorder: 3,
        .layoutReset: 2, .download: 3, .search: 6, .rapidSheets: 3, .rapidTabs: 2,
    ]

    @MainActor private func walk(seed defaultSeed: UInt64, extra: [String]) throws {
        let env = ProcessInfo.processInfo.environment
        let seed = env["MAGPIE_MONKEY_SEED"].flatMap { UInt64($0) } ?? defaultSeed
        let steps = env["MAGPIE_MONKEY_STEPS"].flatMap { Int($0) } ?? 600
        let app = try launchSignedIn(extra)
        var rng = Rng(state: seed)
        let bag = Action.allCases.flatMap { Array(repeating: $0, count: Self.weights[$0] ?? 1) }
        var log: [String] = []
        var hangs: [String] = []
        let clock = ContinuousClock()

        for step in 0..<steps {
            let action = bag.randomElement(using: &rng)!
            let started = clock.now
            slow = []
            // An action that doesn't apply where the app is gives way to another (up to 4); then the walk unsticks.
            var did = perform(action, app, &rng)
            var tried = [action.rawValue]
            for _ in 0..<4 where did == "-" {
                let other = bag.randomElement(using: &rng)!
                tried.append(other.rawValue)
                did = perform(other, app, &rng)
            }
            if did == "-" { did = "- > " + unstick(app, &rng) }
            if tried.count > 1 { did = tried.joined(separator: "/") + " " + did }
            let took = clock.now - started
            let line = String(format: "%03d %@ %@ (%.1fs)", step, action.rawValue, did, Self.seconds(took))
            log.append(line)
            print("MONKEY-STEP " + line)
            if let worst = slow.max() { hangs.append(line + String(format: " slowest interaction %.1fs", Self.seconds(worst))) }
            if app.state != .runningForeground {
                let tail = log.suffix(25).joined(separator: "\n")
                attach(log, name: "monkey-\(seed)-crash")
                XCTFail("the app stopped (state \(app.state.rawValue)) after step \(step), seed \(seed):\n\(tail)")
                return
            }
        }
        attach(log, name: "monkey-\(seed)")
        // Leave the layouts at their defaults (preferences outlive a reset launch).
        resetLayouts(app)
        XCTAssertTrue(hangs.isEmpty, "actions over 5 s (seed \(seed)):\n\(hangs.joined(separator: "\n"))")
        XCTAssertEqual(app.state, .runningForeground)
    }

    private static func seconds(_ d: Duration) -> Double {
        Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    private func attach(_ log: [String], name: String) {
        let attachment = XCTAttachment(string: log.joined(separator: "\n"))
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        print("MONKEY \(name)\n" + log.joined(separator: "\n"))
    }

    // MARK: - Actions

    /// Does `action` if it can from where the app is; returns what it did ("-" when nothing applied).
    @MainActor private func perform(_ action: Action, _ app: XCUIApplication, _ rng: inout Rng) -> String {
        switch action {
        case .tab:
            let name = ["Home", "Library", "Search"].randomElement(using: &rng)!
            return tapIfHittable(app.tabBars.buttons[name]) ? name : "-"
        case .libraryRow:
            let row = ["playlists", "artists", "albums", "songs", "genres", "favourites", "downloads", "recently-added"]
                .randomElement(using: &rng)!
            if !app.buttons["library-\(row)"].exists, app.tabBars.firstMatch.exists, !inSettings(app),
               Int.random(in: 0..<2, using: &rng) == 0 {
                _ = tapIfHittable(app.tabBars.buttons["Library"])   // go there first, half the time
            }
            return tapIfHittable(app.buttons["library-\(row)"]) ? row : "-"
        case .openItem:
            let prefix = ["album-", "genre-group-", "made-for-you-", "artist-notyet-album-", "home-"].randomElement(using: &rng)!
            if prefix == "home-" {   // a tile on a Home shelf
                let shelf = ["jumpBackIn", "recentlyAdded", "mostPlayed", "favourites", "randomAlbums", "playlists", "genres",
                             "downloaded"].randomElement(using: &rng)!
                let tiles = app.descendants(matching: .any).matching(identifier: "home-\(shelf)").firstMatch.buttons
                let tile = tiles.element(boundBy: Int.random(in: 0..<3, using: &rng))
                return tapIfHittable(tile) ? "home-\(shelf)" : "-"
            }
            if prefix == "genre-group-" {
                let any = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'genre-'")).element(
                    boundBy: Int.random(in: 0..<4, using: &rng))
                return tapIfHittable(any) ? "genre" : "-"
            }
            let id = "\(prefix)\(Int.random(in: 0..<6, using: &rng))"
            return tapIfHittable(app.buttons[id]) ? id : "-"
        case .openCell:
            // A row of a list (playlists, artists, a genre's albums); never inside Settings (sign out lives there).
            guard !inSettings(app), app.tabBars.firstMatch.exists else { return "-" }
            let cell = app.cells.element(boundBy: Int.random(in: 0..<5, using: &rng))
            return tapIfHittable(cell) ? "cell" : "-"
        case .play:
            let id = ["track-", "song-", "favourite-song-", "downloads-song-", "made-for-you-track-"].randomElement(using: &rng)!
                + "\(Int.random(in: 0..<5, using: &rng))"
            if tapIfHittable(app.buttons[id]) { return id }
            if Bool.random(using: &rng), playFromAnAlbum(app, &rng) { return "album-path" }
            let shuffle = app.buttons["shuffle"]
            return tapIfHittable(shuffle) ? "shuffle" : "-"
        case .back:
            let bar = app.navigationBars.firstMatch
            guard bar.exists else { return "-" }
            let back = bar.buttons.element(boundBy: 0)
            guard back.exists, back.isHittable, !["Done", "Cancel"].contains(back.label) else { return "-" }
            timed { back.tap() }
            return "back"
        case .edgeSwipe:
            let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.005, dy: 0.5))
            timed {
                from.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)),
                           withVelocity: .fast, thenHoldForDuration: 0)
            }
            return "edge"
        case .scroll:
            if Bool.random(using: &rng) { timedSwipeUp(app, velocity: .fast) } else { timedSwipeDown(app, velocity: .fast) }
            return "scroll"
        case .dismissSheet:
            timedSwipeDown(app, velocity: .fast)
            return "swipe-down"
        case .nowPlaying:
            let mini = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Now playing:'")).firstMatch
            return tapIfHittable(mini) ? "open" : "-"
        case .lyrics:
            openNowPlayingIfPlaying(app)
            if tapIfHittable(app.buttons["lyrics-close"]) { return "close" }
            return tapIfHittable(app.buttons["Lyrics"]) ? "lyrics" : "-"
        case .sleepTimer:
            openNowPlayingIfPlaying(app)
            guard tapIfHittable(app.buttons["Sleep timer"]) else { return "-" }
            // The menu: pick an option, or tap outside to close it.
            let items = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'min' OR label CONTAINS[c] 'end of' OR label CONTAINS[c] 'off'"))
            let item = items.element(boundBy: Int.random(in: 0..<4, using: &rng))
            if Bool.random(using: &rng), let label = tapIfHittable(item, named: \.label) { return "timer:\(label)" }
            timed { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap() }
            return "timer-menu"
        case .queue:
            if app.navigationBars["Queue"].exists {
                timedSwipeDown(app.navigationBars["Queue"], velocity: .fast)
                return "close"
            }
            openNowPlayingIfPlaying(app)
            let opener = Bool.random(using: &rng) ? app.buttons["Queue"]
                : app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Up next'")).firstMatch
            return tapIfHittable(opener) ? "open" : "-"
        case .queueControls:
            let id = ["queue-shuffle", "queue-repeat", "queue-shuffle", "queue-repeat", "queue-clear"].randomElement(using: &rng)!
            return tapIfHittable(app.buttons[id]) ? id : "-"
        case .playPause:
            return tapIfHittable(app.buttons["np-play-pause"]) ? "np-play-pause" : "-"
        case .settings:
            if tapIfHittable(app.buttons["settings-done"]) { return "done" }
            if !app.buttons["open-settings"].exists { _ = tapIfHittable(app.tabBars.buttons["Library"]) }
            return tapIfHittable(app.buttons["open-settings"]) ? "open" : "-"
        case .settingsPage:
            let page = ["playback", "downloads", "listenbrainz", "home-library", "appearance", "about"].randomElement(using: &rng)!
            if tapIfHittable(app.buttons["settings-\(page)"]) { return page }
            let sub = ["settings-home-layout", "settings-library-layout"].randomElement(using: &rng)!
            return tapIfHittable(app.buttons[sub]) ? sub : "-"
        case .settingsToggle:
            guard inSettings(app) else { return "-" }
            if Bool.random(using: &rng) {
                let id = ["character-signature", "character-classic", "character-immersive", "accent-0", "accent-1"]
                    .randomElement(using: &rng)!
                if tapIfHittable(app.buttons[id]) { return id }
            }
            let toggle = app.switches.element(boundBy: Int.random(in: 0..<6, using: &rng))
            return tapIfHittable(toggle, named: \.label).map { "switch:\($0)" } ?? "-"
        case .homeEditor:
            if tapIfHittable(app.buttons["home-edit-done"]) { return "done" }
            if !app.buttons["home-edit"].exists { _ = tapIfHittable(app.tabBars.buttons["Home"]) }
            let edit = app.buttons["home-edit"]
            for _ in 0..<3 where edit.exists && !edit.isHittable { timedSwipeUp(app, velocity: .fast) }
            return tapIfHittable(edit) ? "open" : "-"
        case .layoutToggle:
            let toggles = app.switches.matching(NSPredicate(format: "identifier BEGINSWITH 'layout-'"))
            let toggle = toggles.element(boundBy: Int.random(in: 0..<8, using: &rng))
            return tapIfHittable(toggle, named: \.identifier) ?? "-"
        case .layoutReorder:
            let handles = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Reorder'"))
            let count = min(handles.count, 9)
            guard count >= 2 else { return "-" }
            let a = handles.element(boundBy: Int.random(in: 0..<count, using: &rng))
            let b = handles.element(boundBy: Int.random(in: 0..<count, using: &rng))
            guard a.isHittable, b.isHittable else { return "-" }
            timed { a.press(forDuration: 0.6, thenDragTo: b) }
            return "reorder"
        case .layoutReset:
            return tapIfHittable(app.buttons["layout-reset"]) ? "reset" : "-"
        case .download:
            let download = app.buttons["download"]
            guard tapIfHittable(download) else { return "-" }
            // A second tap on a downloading or downloaded album opens its menu: cancel or remove it.
            let remove = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Remove download' OR label BEGINSWITH 'Cancel'")).firstMatch
            if remove.waitForExistence(timeout: 1), Bool.random(using: &rng) {
                timed { remove.tap() }
                return "remove"
            }
            if remove.exists { timed { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap() } }
            return "download"
        case .search:
            let field = app.searchFields.firstMatch
            if !field.exists { _ = tapIfHittable(app.tabBars.buttons["Search"]) }
            guard field.waitForExistence(timeout: 2), field.isHittable else { return "-" }
            timed { field.tap() }
            switch Int.random(in: 0..<5, using: &rng) {
            case 0:
                timedType(field, String(repeating: XCUIKeyboardKey.delete.rawValue, count: Int.random(in: 1...4, using: &rng)))
                return "delete"
            case 1:
                let clear = field.buttons["Clear text"]
                if tapIfHittable(clear) { return "clear" }
                return "-"
            default:
                let text = String((0..<Int.random(in: 1...4, using: &rng)).map { _ in "aeiounrst ".randomElement(using: &rng)! })
                timedType(field, text)
                return "type:\(text)"
            }
        case .rapidSheets:
            // Present and dismiss at once, a few times: Settings, Now Playing, the Home editor.
            var did: [String] = []
            for _ in 0..<3 {
                switch Int.random(in: 0..<3, using: &rng) {
                case 0:
                    if tapIfHittable(app.buttons["open-settings"]) {
                        _ = tapIfHittable(app.buttons["settings-done"]) || swipeDown(app)
                        did.append("settings")
                    }
                case 1:
                    let mini = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Now playing:'")).firstMatch
                    if tapIfHittable(mini) { timedSwipeDown(app, velocity: .fast); did.append("np") }
                default:
                    if tapIfHittable(app.buttons["home-edit"]) {
                        _ = tapIfHittable(app.buttons["home-edit-done"]) || swipeDown(app)
                        did.append("home-edit")
                    }
                }
            }
            return did.isEmpty ? "-" : did.joined(separator: ",")
        case .rapidTabs:
            for _ in 0..<5 {
                let name = ["Home", "Library", "Search"].randomElement(using: &rng)!
                let button = app.tabBars.buttons[name]
                if button.exists { timed { button.tap() } }
            }
            return "tabs"
        }
    }

    /// One interaction, timed: XCUITest waits for the app to go idle after it, so a main thread that is stuck (a
    /// layout loop, synchronous work) shows up here as a slow interaction.
    @MainActor private func timed(_ body: () -> Void) {
        let started = ContinuousClock.now
        body()
        let took = ContinuousClock.now - started
        if took > .seconds(5) { slow.append(took) }
    }

    @MainActor private func timedType(_ element: XCUIElement, _ text: String) { timed { element.typeText(text) } }
    @MainActor private func timedSwipeUp(_ element: XCUIElement, velocity: XCUIGestureVelocity = .default) {
        timed { element.swipeUp(velocity: velocity) }
    }
    @MainActor private func timedSwipeDown(_ element: XCUIElement, velocity: XCUIGestureVelocity = .default) {
        timed { element.swipeDown(velocity: velocity) }
    }

    /// Nothing applied where the app is: get somewhere that offers more (put the keyboard away, close a sheet, or
    /// change tab).
    @MainActor private func unstick(_ app: XCUIApplication, _ rng: inout Rng) -> String {
        if app.keyboards.firstMatch.exists {
            let cancel = app.buttons["Cancel"]
            if tapIfHittable(cancel) { return "cancel-search" }
            let close = app.buttons["Close"]
            if tapIfHittable(close) { return "close-search" }
        }
        if !app.tabBars.firstMatch.exists || !app.tabBars.firstMatch.isHittable {
            if tapIfHittable(app.buttons["settings-done"]) { return "settings-done" }
            if tapIfHittable(app.buttons["home-edit-done"]) { return "home-edit-done" }
            timedSwipeDown(app, velocity: .fast)
            return "swipe-down"
        }
        let name = ["Home", "Library", "Search"].randomElement(using: &rng)!
        return tapIfHittable(app.tabBars.buttons[name]) ? "tab:\(name)" : "stuck"
    }

    /// Library › Albums › a random album › a random track (each step only if the tab bar is up).
    @MainActor private func playFromAnAlbum(_ app: XCUIApplication, _ rng: inout Rng) -> Bool {
        guard app.tabBars.firstMatch.exists, !inSettings(app) else { return false }
        _ = tapIfHittable(app.tabBars.buttons["Library"])
        // Back to the Library root if a page is pushed.
        for _ in 0..<4 where !app.buttons["library-albums"].exists {
            let back = app.navigationBars.firstMatch.buttons.element(boundBy: 0)
            guard back.exists, back.isHittable else { break }
            timed { back.tap() }
        }
        guard tapIfHittable(app.buttons["library-albums"]) else { return false }
        let album = app.buttons["album-\(Int.random(in: 0..<6, using: &rng))"]
        guard album.waitForExistence(timeout: 5), tapIfHittable(album) else { return false }
        let track = app.buttons["track-\(Int.random(in: 0..<4, using: &rng))"]
        guard track.waitForExistence(timeout: 5) else { return false }
        return tapIfHittable(track)
    }

    /// Opens Now Playing when something is queued and it isn't already up.
    @MainActor private func openNowPlayingIfPlaying(_ app: XCUIApplication) {
        guard !app.buttons["np-play-pause"].exists else { return }
        let mini = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Now playing:'")).firstMatch
        _ = tapIfHittable(mini)
    }

    @MainActor private func swipeDown(_ app: XCUIApplication) -> Bool {
        timedSwipeDown(app, velocity: .fast)
        return true
    }

    @MainActor private func inSettings(_ app: XCUIApplication) -> Bool {
        app.buttons["settings-done"].exists
    }

    /// Taps `element` if it is there, returning its name read before the tap (a menu item is gone after it).
    @MainActor private func tapIfHittable(_ element: XCUIElement, named key: KeyPath<XCUIElement, String>) -> String? {
        guard element.exists, element.isHittable else { return nil }
        let name = element[keyPath: key]
        timed { element.tap() }
        return name
    }

    @MainActor private func tapIfHittable(_ element: XCUIElement) -> Bool {
        guard element.exists, element.isHittable else { return false }
        timed { element.tap() }
        return true
    }

    @MainActor private func resetLayouts(_ app: XCUIApplication) {
        for _ in 0..<3 where !app.tabBars.firstMatch.exists { timedSwipeDown(app, velocity: .fast) }
        if app.buttons["settings-done"].exists { timed { app.buttons["settings-done"].tap() } }
        _ = tapIfHittable(app.tabBars.buttons["Library"])
        guard tapIfHittable(app.buttons["open-settings"]) else { return }
        _ = tapIfHittable(app.buttons["settings-home-library"])
        for editor in ["settings-home-layout", "settings-library-layout"] {
            guard tapIfHittable(app.buttons[editor]) else { continue }
            let reset = app.buttons["layout-reset"]
            for _ in 0..<4 where reset.exists && !reset.isHittable { timedSwipeUp(app) }
            _ = tapIfHittable(reset)
            _ = tapIfHittable(app.navigationBars.buttons.element(boundBy: 0))
        }
        _ = tapIfHittable(app.buttons["settings-done"])
    }
}
