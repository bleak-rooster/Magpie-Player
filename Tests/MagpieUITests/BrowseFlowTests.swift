import XCTest

/// Signs in to the local dev stack, opens the first album and plays its first track.
/// Runs only with `MAGPIE_IT=1 scripts/test-app.sh`, which passes the dev-stack address and
/// credentials from `dev/.env.local` as TEST_RUNNER_ variables. Guard G0: localhost only.
final class BrowseFlowTests: XCTestCase {
    private struct DevStack {
        var url: String
        var user: String
        var password: String
    }

    private func devStack() throws -> DevStack {
        let env = ProcessInfo.processInfo.environment
        guard env["MAGPIE_IT"] == "1" else { throw XCTSkip("set MAGPIE_IT=1 (MAGPIE_IT=1 scripts/test-app.sh) to run") }
        guard let url = env["MAGPIE_IT_URL"], let user = env["MAGPIE_IT_USER"], let password = env["MAGPIE_IT_PASSWORD"],
              !url.isEmpty, !user.isEmpty, !password.isEmpty else {
            XCTFail("MAGPIE_IT=1 but the dev-stack URL/credentials were not passed in")
            throw XCTSkip("missing dev-stack environment")
        }
        guard let host = URLComponents(string: url)?.host, ["127.0.0.1", "localhost"].contains(host) else {
            XCTFail("Refusing to run against a non-local server (\(url)); the UI test only talks to the dev stack")
            throw XCTSkip("non-local server")
        }
        return DevStack(url: url, user: user, password: password)
    }

    /// Launches signed out, signs in to the dev stack and waits for the tab bar.
    @MainActor private func launchSignedIn(_ arguments: [String] = []) throws -> XCUIApplication {
        let stack = try devStack()
        continueAfterFailure = false
        let app = XCUIApplication()
        // -MagpieResetLayouts: a layout test that failed half-way never leaves Songs hidden for the next one.
        app.launchArguments = ["-MagpieResetState", "YES", "-MagpieUITesting", "YES", "-MagpieResetLayouts", "YES",
                               "-MagpieNetwork", "wifi"] + arguments
        app.launch()

        let address = app.textFields["connect-address-0"]
        XCTAssertTrue(address.waitForExistence(timeout: 10))
        address.tap()
        address.typeText(stack.url)
        let user = app.textFields["connect-username"]
        user.tap()
        user.typeText(stack.user)
        let password = app.secureTextFields["connect-password"]
        password.tap()
        password.typeText(stack.password)
        app.buttons["connect-continue"].tap()

        // iOS offers to save the password 1-3 s after Continue. The button exists while the prompt is still
        // sliding in, and a tap then can be lost; a prompt left up swallows the next tap outside it (that tap
        // only dismisses it). Tap until it is gone.
        let notNow = app.buttons["Not Now"]
        if notNow.waitForExistence(timeout: 5) {
            for _ in 0..<3 where notNow.exists {
                notNow.tap()
                _ = notNow.waitForNonExistence(timeout: 2)
            }
        }
        XCTAssertTrue(app.tabBars.buttons["Library"].waitForExistence(timeout: 20),
                      "did not reach the tabs; error: \(errorText(app))")
        return app
    }

    /// P2: Library › Songs has the right-edge letter index; touching T shows the dev library's T song, and the index
    /// reads to VoiceOver as one "Letter index".
    @MainActor func testSongsLetterIndexJumps() throws {
        let app = try launchSignedIn()
        let library = app.tabBars.buttons["Library"]
        let songs = app.buttons["library-songs"]
        for _ in 0..<3 where !songs.exists {
            library.tap()
            _ = songs.waitForExistence(timeout: 5)
        }
        songs.tap()
        XCTAssertTrue(app.buttons["song-0"].waitForExistence(timeout: 15))
        let index = app.otherElements["letter-index"].exists ? app.otherElements["letter-index"]
                                                             : app.descendants(matching: .any)["letter-index"]
        XCTAssertTrue(index.waitForExistence(timeout: 5), "the letter index")
        XCTAssertEqual(index.label, "Letter index")
        // 8 pt padding, then 13 pt a letter: "#", A … Z. T is the 21st.
        index.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0))
            .withOffset(CGVector(dx: 0, dy: 8 + 20.5 * 13)).tap()
        let terra = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Terra Incognita'")).firstMatch
        XCTAssertTrue(terra.waitForExistence(timeout: 5))
        XCTAssertTrue(terra.isHittable, "scrolled to T")
        XCTAssertFalse(app.buttons["song-0"].isHittable, "the top of the list scrolled away")
        attachScreenshot(app, "songs-letter-index")
    }

    /// P2 (review ⚠️): the Albums grid's letter index lands: touching P scrolls the grid to "Paper Planes".
    @MainActor func testAlbumsLetterIndexJumps() throws {
        let app = try launchSignedIn()
        let library = app.tabBars.buttons["Library"]
        let albums = app.buttons["library-albums"]
        for _ in 0..<3 where !albums.exists {
            library.tap()
            _ = albums.waitForExistence(timeout: 5)
        }
        albums.tap()
        let first = app.buttons["album-0"]
        XCTAssertTrue(first.waitForExistence(timeout: 15))
        let firstTop = first.frame.minY
        let paper = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Paper Planes'")).firstMatch
        XCTAssertTrue(paper.waitForExistence(timeout: 5))
        let before = paper.frame.minY
        let index = app.descendants(matching: .any)["letter-index"]
        XCTAssertTrue(index.waitForExistence(timeout: 5), "the letter index")
        // 8 pt padding, then 13 pt a letter: "#", A … Z. P is the 17th.
        index.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0))
            .withOffset(CGVector(dx: 0, dy: 8 + 16.5 * 13)).tap()
        let moved = NSPredicate { _, _ in paper.frame.minY < before - 50 }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: moved, object: nil)], timeout: 5), .completed,
                       "the grid scrolled towards P")
        XCTAssertTrue(paper.isHittable, "Paper Planes is in view")
        XCTAssertLessThan(first.frame.minY, firstTop, "the top of the grid moved up")
        attachScreenshot(app, "albums-letter-index")
    }

    @MainActor func testSignInBrowsePlay() throws {
        let app = try launchSignedIn()
        let library = app.tabBars.buttons["Library"]
        // Library › Albums › first album. The tab bar can swallow a tap while it settles; tap again if so.
        let albums = app.buttons["library-albums"]
        for _ in 0..<3 where !albums.exists {
            library.tap()
            _ = albums.waitForExistence(timeout: 5)
        }
        albums.tap()
        let firstAlbum = app.buttons["album-0"]
        XCTAssertTrue(firstAlbum.waitForExistence(timeout: 15))
        firstAlbum.tap()

        // First track: remember its title, play it
        let firstTrack = app.buttons["track-0"]
        XCTAssertTrue(firstTrack.waitForExistence(timeout: 15))
        let title = firstTrack.label
        XCTAssertFalse(title.isEmpty)
        firstTrack.tap()

        // The mini player shows that title.
        let mini = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Now playing: \(title),")).firstMatch
        XCTAssertTrue(mini.waitForExistence(timeout: 15), "mini player did not show \(title)")
    }

    /// R12 fix C2: a row swiped part-way rests open, and its revealed button takes the tap. With nothing playing, the
    /// album's first track swiped left and its Play next tapped starts it (the tap-to-close layer must not cover it).
    @MainActor func testRevealedSwipeButtonTakesTheTap() throws {
        let app = try launchSignedIn()
        let library = app.tabBars.buttons["Library"]
        let albums = app.buttons["library-albums"]
        for _ in 0..<3 where !albums.exists {
            library.tap()
            _ = albums.waitForExistence(timeout: 5)
        }
        albums.tap()
        let firstAlbum = app.buttons["album-0"]
        XCTAssertTrue(firstAlbum.waitForExistence(timeout: 15))
        firstAlbum.tap()
        let track = app.buttons["track-0"]
        XCTAssertTrue(track.waitForExistence(timeout: 15))
        let title = track.label
        // A slow, part-way drag to the left: short of a full swipe, so the row rests open on Play next.
        track.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: track.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.5)),
                   withVelocity: .slow, thenHoldForDuration: 0.1)
        Thread.sleep(forTimeInterval: 0.6)
        attachScreenshot(app, "swipe-open")
        let mini = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Now playing:")).firstMatch
        let toast = app.descendants(matching: .any)["library-notice"]
        XCTAssertFalse(mini.exists, "nothing plays until the button is tapped; toast: \(toast.exists ? toast.label : "none")")
        // The revealed button sits at the row's trailing edge.
        track.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.5)).tap()
        let playing = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Now playing: \(title),")).firstMatch
        XCTAssertTrue(playing.waitForExistence(timeout: 15), "Play next on the revealed button didn't queue \(title)")
        // Vertical drags on the rows still scroll the page (the row swipe takes only sideways drags).
        let before = track.frame.minY
        // From the row itself (track 1 sits under the mini player).
        track.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: track.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: -6)))
        Thread.sleep(forTimeInterval: 1)
        XCTAssertLessThan(track.frame.minY, before - 20, "a vertical drag starting on a row didn't scroll the page")
    }

    /// T12: the album's Download control is one button to VoiceOver, labelled "Download" with the status as its
    /// value, and activating it by that label downloads the album; its menu then removes the download.
    @MainActor func testAlbumDownloadButtonActivatesByLabel() throws {
        let app = try launchSignedIn()
        let library = app.tabBars.buttons["Library"]
        let albums = app.buttons["library-albums"]
        for _ in 0..<3 where !albums.exists {
            library.tap()
            _ = albums.waitForExistence(timeout: 5)
        }
        albums.tap()
        let firstAlbum = app.buttons["album-0"]
        XCTAssertTrue(firstAlbum.waitForExistence(timeout: 15))
        firstAlbum.tap()

        let download = app.buttons.matching(NSPredicate(format: "label == %@ AND identifier == %@", "Download", "download")).firstMatch
        XCTAssertTrue(download.waitForExistence(timeout: 15), "no button labelled Download")
        XCTAssertEqual(download.value as? String ?? "", "")
        download.tap()
        // The status keeps the button trait (it is still found among buttons) and reads as the value.
        expectation(for: NSPredicate(format: "value == 'Downloaded'"), evaluatedWith: download)
        waitForExpectations(timeout: 60)
        XCTAssertEqual(download.elementType, .button)

        // Clean up: the menu's Remove download takes the album off the simulator again.
        download.tap()
        let remove = app.buttons["Remove download"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        remove.tap()
        expectation(for: NSPredicate(format: "value == ''"), evaluatedWith: download)
        waitForExpectations(timeout: 15)
    }

    /// Queue crash hunt (owner report, build 3): open and close the queue again and again, from the Queue button and the Up next row,
    /// with lyrics on when the server has them, and a quick double tap.
    @MainActor func testQueueReopensRepeatedly() throws {
        let app = try launchSignedIn()
        let nowPlaying = openNowPlaying(app)
        let lyrics = nowPlaying.buttons["Lyrics"]
        if lyrics.waitForExistence(timeout: 5) { lyrics.tap() }
        for i in 0..<8 {
            let opener = i % 2 == 0 ? nowPlaying.buttons["Queue"]
                : app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Up next'")).firstMatch
            guard opener.waitForExistence(timeout: 5) else { continue }
            if i == 4 { opener.doubleTap() } else { opener.tap() }
            XCTAssertTrue(app.navigationBars["Queue"].waitForExistence(timeout: 10), "open \(i)")
            Thread.sleep(forTimeInterval: 1.5)
            XCTAssertEqual(app.state, .runningForeground, "the app quit on open \(i)")
            app.navigationBars["Queue"].swipeDown(velocity: .fast)
            if app.navigationBars["Queue"].exists { app.swipeDown(velocity: .fast) }
            _ = app.navigationBars["Queue"].waitForNonExistence(timeout: 5)
            XCTAssertEqual(app.state, .runningForeground, "the app quit on close \(i)")
        }
    }

    /// Queue crash hunt (owner report, build 3): Play Next / Add to Queue from Search, then the queue's own controls.
    @MainActor func testQueueAfterPlayNextAndModes() throws {
        let app = try launchSignedIn()
        _ = openNowPlaying(app)
        app.buttons["Close Now Playing"].tap()
        let field = app.searchFields.firstMatch
        for _ in 0..<3 where !field.exists {
            app.tabBars.buttons["Search"].tap()
            _ = field.waitForExistence(timeout: 5)
        }
        field.tap()
        field.typeText("Paper Planes")
        let song = app.buttons["search-song-0"]
        XCTAssertTrue(song.waitForExistence(timeout: 15))
        app.keyboards.buttons["search"].tap()
        for action in ["Play next", "Add to queue", "Play next"] {
            song.press(forDuration: 1.5)
            let item = app.buttons[action]
            XCTAssertTrue(item.waitForExistence(timeout: 5), action)
            item.tap()
            Thread.sleep(forTimeInterval: 1)
        }
        attachScreenshot(app, "after-context")
        let mini = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Now playing:")).firstMatch
        XCTAssertTrue(mini.waitForExistence(timeout: 10))
        for _ in 0..<3 where !app.buttons["np-play-pause"].exists {
            mini.tap()
            _ = app.buttons["np-play-pause"].waitForExistence(timeout: 5)
        }
        app.otherElements["now-playing"].buttons["Queue"].tap()
        XCTAssertTrue(app.navigationBars["Queue"].waitForExistence(timeout: 10))
        attachScreenshot(app, "queue-upnext")
        // Songs end with Up Next filled while the queue stays open.
        for i in 0..<12 {
            Thread.sleep(forTimeInterval: 4)
            XCTAssertEqual(app.state, .runningForeground, "the app quit with Up Next after \((i + 1) * 4) s")
        }
        attachScreenshot(app, "queue-upnext-later")
        for id in ["queue-shuffle", "queue-repeat", "queue-repeat", "queue-shuffle", "queue-repeat"] {
            let b = app.buttons[id]
            if b.waitForExistence(timeout: 3) { b.tap() }
            Thread.sleep(forTimeInterval: 0.5)
            XCTAssertEqual(app.state, .runningForeground, "after \(id)")
        }
        app.buttons["queue-clear"].tap()
        let clear = app.buttons.matching(identifier: "Clear")
        if clear.count > 1 { clear.element(boundBy: clear.count - 1).tap() }
        Thread.sleep(forTimeInterval: 2)
        XCTAssertEqual(app.state, .runningForeground, "after clear")
    }

    /// T10b (D43): Now Playing fits one screen at the default text size, with no page scrolling; Lyrics swaps the
    /// art for the lyrics and back. P6: the lyrics fill the page down to a compact title line above the scrubber.
    @MainActor func testNowPlayingFitsOneScreenAndTogglesLyrics() throws {
        let app = try launchSignedIn()
        let nowPlaying = openNowPlaying(app)
        let playPause = app.buttons["np-play-pause"]
        // Everything is reachable without a swipe, and nothing on the page scrolls.
        XCTAssertTrue(playPause.isHittable, "play/pause")
        XCTAssertTrue(nowPlaying.buttons["Next"].isHittable, "next")
        XCTAssertTrue(nowPlaying.buttons["Queue"].isHittable, "queue")
        XCTAssertTrue(nowPlaying.buttons["Sleep timer"].isHittable, "sleep timer")
        XCTAssertEqual(nowPlaying.scrollViews.count, 0, "Now Playing scrolls at the default text size")
        attachScreenshot(app, "now-playing-signature")

        let lyricsButton = nowPlaying.buttons["Lyrics"]
        // The server's songLyrics check runs as the sheet opens; give it a moment before deciding.
        guard lyricsButton.waitForExistence(timeout: 5) else {
            // Recorded reason: the dev stack doesn't advertise songLyrics, so the button is rightly hidden.
            XCTAssertFalse(lyricsButton.exists, "Lyrics must stay hidden until the server advertises songLyrics")
            XCTContext.runActivity(named: "Lyrics toggle not exercised: the dev stack doesn't advertise songLyrics") { _ in }
            return
        }
        XCTAssertTrue(lyricsButton.isHittable, "lyrics")
        XCTAssertFalse(lyricsButton.isSelected)

        lyricsButton.tap()
        let lyrics = app.descendants(matching: .any)["np-lyrics"]
        XCTAssertTrue(lyrics.waitForExistence(timeout: 5), "lyrics did not appear in the art's place")
        XCTAssertTrue(lyricsButton.isSelected, "the Lyrics button shows its on state")
        // P6: full width and taller than the art's square, above the compact title line; the only thing that
        // scrolls is inside it.
        XCTAssertGreaterThan(lyrics.frame.width, app.frame.width * 0.8, "lyrics not full width")
        XCTAssertGreaterThan(lyrics.frame.height, lyrics.frame.width, "lyrics no bigger than the art")
        let compact = app.descendants(matching: .any)["np-title-compact"]
        XCTAssertTrue(compact.waitForExistence(timeout: 5), "the compact title line is missing")
        XCTAssertLessThanOrEqual(lyrics.frame.maxY, compact.frame.minY + 1)
        XCTAssertEqual(nowPlaying.scrollViews.count, lyrics.scrollViews.count, "the page itself scrolls")
        XCTAssertTrue(playPause.isHittable)
        // Either lyrics or the "no lyrics" state shows, inside the slot.
        let loaded = lyrics.staticTexts["Lyrics from your library"]
        let empty = app.descendants(matching: .any)["lyrics-empty"]
        XCTAssertTrue(loaded.waitForExistence(timeout: 10) || empty.exists, "the slot shows neither lyrics nor the empty state")
        attachScreenshot(app, "now-playing-signature-lyrics")

        // Lyrics again brings the art back; so does the slot's close button.
        lyricsButton.tap()
        XCTAssertTrue(lyrics.waitForNonExistence(timeout: 5), "the art did not come back")
        XCTAssertFalse(lyricsButton.isSelected)
        XCTAssertEqual(nowPlaying.scrollViews.count, 0)
        lyricsButton.tap()
        XCTAssertTrue(lyrics.waitForExistence(timeout: 5))
        app.buttons["lyrics-close"].tap()
        XCTAssertTrue(lyrics.waitForNonExistence(timeout: 5), "close did not bring the art back")
    }

    /// T10b (D43): Immersive fits one screen too.
    @MainActor func testNowPlayingImmersiveFitsOneScreen() throws {
        let app = try launchSignedIn(["-MagpieCharacter", "immersive"])
        let nowPlaying = openNowPlaying(app)
        XCTAssertTrue(app.buttons["np-play-pause"].isHittable, "play/pause")
        XCTAssertTrue(nowPlaying.buttons["Next"].isHittable, "next")
        XCTAssertTrue(nowPlaying.buttons["Queue"].isHittable, "queue")
        XCTAssertTrue(nowPlaying.buttons["Sleep timer"].isHittable, "sleep timer")
        XCTAssertEqual(nowPlaying.scrollViews.count, 0, "Now Playing scrolls at the default text size")
        attachScreenshot(app, "now-playing-immersive")
    }

    /// Owner report (TestFlight 0.0.1 build 3): opening Queue from Now Playing while music plays crashed the app.
    /// Each look opens the queue sheet while a song plays, and the queue lists what's playing and what's next.
    @MainActor func testQueueOpensWhilePlayingInEveryLook() throws {
        for character in ["signature", "classic", "immersive"] {
            try XCTContext.runActivity(named: character) { _ in
                let app = try launchSignedIn(["-MagpieCharacter", character])
                let nowPlaying = openNowPlaying(app)
                let queue = nowPlaying.buttons["Queue"]
                XCTAssertTrue(queue.waitForExistence(timeout: 5))
                queue.tap()
                XCTAssertTrue(app.navigationBars["Queue"].waitForExistence(timeout: 10), "the queue did not open (\(character))")
                XCTAssertTrue(app.staticTexts["Now playing"].waitForExistence(timeout: 5))
                XCTAssertTrue(app.staticTexts["Playing next"].waitForExistence(timeout: 5))
                // Let it play on with the queue open: the time ticks and Up next refreshes.
                Thread.sleep(forTimeInterval: 3)
                XCTAssertEqual(app.state, .runningForeground, "the app quit with the queue open (\(character))")
                attachScreenshot(app, "queue-\(character)")
                app.terminate()
            }
        }
    }

    /// Queue crash hunt (owner report, build 3): queue open through several song changes, then Edit, move and swipe-delete.
    @MainActor func testQueueStaysUpThroughSongChangesAndEdits() throws {
        let app = try launchSignedIn()
        // Search › Paper Planes › Play Next lands in Up Next once an album plays.
        let nowPlaying = openNowPlaying(app)
        nowPlaying.buttons["Queue"].tap()
        XCTAssertTrue(app.navigationBars["Queue"].waitForExistence(timeout: 10))
        for i in 0..<10 {
            Thread.sleep(forTimeInterval: 4)
            XCTAssertEqual(app.state, .runningForeground, "the app quit with the queue open after \((i + 1) * 4) s")
        }
        app.buttons["Edit"].tap()
        Thread.sleep(forTimeInterval: 1)
        let cells = app.cells
        if cells.count > 4 {
            let handle = cells.element(boundBy: cells.count - 1).buttons.matching(NSPredicate(format: "label BEGINSWITH 'Reorder'")).firstMatch
            if handle.exists { handle.press(forDuration: 0.5, thenDragTo: cells.element(boundBy: 2)) }
        }
        XCTAssertEqual(app.state, .runningForeground, "the app quit after a move")
        app.buttons["Done"].tap()
        let last = cells.element(boundBy: cells.count - 1)
        last.swipeLeft()
        if app.buttons["Delete"].waitForExistence(timeout: 2) { app.buttons["Delete"].tap() }
        Thread.sleep(forTimeInterval: 2)
        XCTAssertEqual(app.state, .runningForeground, "the app quit after a delete")
        attachScreenshot(app, "queue-after-edits")
    }

    /// Library › Albums › first album › first track, then the mini player opens Now Playing.
    @MainActor private func openNowPlaying(_ app: XCUIApplication) -> XCUIElement {
        let library = app.tabBars.buttons["Library"]
        let albums = app.buttons["library-albums"]
        for _ in 0..<3 where !albums.exists {
            library.tap()
            _ = albums.waitForExistence(timeout: 5)
        }
        albums.tap()
        let firstAlbum = app.buttons["album-0"]
        XCTAssertTrue(firstAlbum.waitForExistence(timeout: 15))
        firstAlbum.tap()
        let firstTrack = app.buttons["track-0"]
        XCTAssertTrue(firstTrack.waitForExistence(timeout: 15))
        let title = firstTrack.label
        firstTrack.tap()
        let mini = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Now playing: \(title),")).firstMatch
        XCTAssertTrue(mini.waitForExistence(timeout: 15), "mini player did not show \(title)")
        mini.tap()
        XCTAssertTrue(app.buttons["np-play-pause"].waitForExistence(timeout: 10), "Now Playing did not open")
        let nowPlaying = app.otherElements["now-playing"]
        XCTAssertTrue(nowPlaying.exists)
        return nowPlaying
    }

    @MainActor private func attachScreenshot(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Search tab: type a name from the dev library, tap the first song, see it in the mini player.
    @MainActor func testSearchAndPlay() throws {
        let app = try launchSignedIn()
        // The tab bar can swallow a tap while it settles; tap again if so.
        let field = app.searchFields.firstMatch
        for _ in 0..<3 where !field.exists {
            app.tabBars.buttons["Search"].tap()
            _ = field.waitForExistence(timeout: 5)
        }
        XCTAssertTrue(field.exists, "search field not found")
        field.tap()
        field.typeText("Paper Planes")
        let song = app.buttons["search-song-0"]
        XCTAssertTrue(song.waitForExistence(timeout: 15), "no song result for the dev library's Paper Planes")
        let title = song.label.components(separatedBy: ", ").first ?? song.label
        song.tap()
        let mini = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Now playing: \(title),")).firstMatch
        XCTAssertTrue(mini.waitForExistence(timeout: 15), "mini player did not show \(title)")
    }

    /// R19 bug: tapping an Artists or Albums search result did nothing (only songs acted). Each opens its page.
    @MainActor func testSearchArtistAndAlbumResultsOpenTheirPages() throws {
        let app = try launchSignedIn()
        let field = app.searchFields.firstMatch
        for _ in 0..<3 where !field.exists {
            app.tabBars.buttons["Search"].tap()
            _ = field.waitForExistence(timeout: 5)
        }
        field.tap()
        field.typeText("Aurora Field")
        // The Artists scope, so the row is on screen (the songs come first in All).
        let artistsScope = app.buttons["Artists"].firstMatch
        XCTAssertTrue(artistsScope.waitForExistence(timeout: 5))
        artistsScope.tap()
        let artist = app.descendants(matching: .any)["search-artist-0"]
        XCTAssertTrue(artist.waitForExistence(timeout: 15), "no artist result for the dev library's Aurora Field")
        artist.tap()
        XCTAssertTrue(app.navigationBars["Aurora Field"].waitForExistence(timeout: 10), "the artist result opened nothing")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        field.tap()
        field.clearAndType("Continuum")
        app.buttons["Albums"].firstMatch.tap()
        let album = app.descendants(matching: .any)["search-album-0"]
        XCTAssertTrue(album.waitForExistence(timeout: 15), "no album result for the dev library's Continuum")
        album.tap()
        XCTAssertTrue(app.descendants(matching: .any)["track-0"].waitForExistence(timeout: 10), "the album result opened nothing")
    }

    /// Home › Finish setting up › connect the dev stack's Lidarr: the read-only summary appears
    /// (version, sign-in, root folders, ...). Disconnects again so the next run starts clean.
    @MainActor func testConnectLidarrShowsSummary() throws {
        let env = ProcessInfo.processInfo.environment
        guard let lidarrURL = env["MAGPIE_IT_LIDARR_URL"], let key = env["MAGPIE_IT_LIDARR_KEY"],
              !lidarrURL.isEmpty, !key.isEmpty else { throw XCTSkip("no dev-stack Lidarr passed in") }
        guard let host = URLComponents(string: lidarrURL)?.host, ["127.0.0.1", "localhost"].contains(host) else {
            XCTFail("Refusing a non-local Lidarr (\(lidarrURL))")
            return
        }
        let app = try launchSignedIn()
        let card = app.buttons["finish-setting-up"]
        for _ in 0..<3 where !card.exists {
            app.tabBars.buttons["Home"].tap()
            _ = card.waitForExistence(timeout: 5)
        }
        card.tap()
        let address = app.textFields["lidarr-address"]
        XCTAssertTrue(address.waitForExistence(timeout: 10))
        address.tap()
        address.typeText(lidarrURL)
        let apiKey = app.secureTextFields["lidarr-api-key"]
        apiKey.tap()
        apiKey.typeText(key)
        app.buttons["lidarr-connect"].tap()

        func labelled(_ prefix: String) -> XCUIElement {
            app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
        }
        let error = app.staticTexts["lidarr-error"]
        XCTAssertTrue(labelled("Version").waitForExistence(timeout: 20),
                      "did not connect to the dev Lidarr; error: \(error.exists ? error.label : "none")")
        XCTAssertTrue(labelled("Root folders").exists)
        XCTAssertTrue(labelled("Recycle bin").exists)
        // The form is lazy: scroll to the bottom for Disconnect.
        let disconnect = app.buttons["Disconnect Lidarr"]
        for _ in 0..<6 where !disconnect.exists { app.swipeUp() }
        disconnect.tap()
        XCTAssertTrue(app.textFields["lidarr-address"].waitForExistence(timeout: 10))
    }

    /// Connects the dev Lidarr, allows changes, sets Magpie up, sets Add with my defaults, and opens Aurora Field's
    /// page ("Not in Lidarr"). Nothing is written to Lidarr except Magpie's set-up (already there).
    @MainActor private func openAuroraWithLidarr(withMyDefaults: Bool) throws -> XCUIApplication {
        let env = ProcessInfo.processInfo.environment
        guard let lidarrURL = env["MAGPIE_IT_LIDARR_URL"], let key = env["MAGPIE_IT_LIDARR_KEY"],
              !lidarrURL.isEmpty, !key.isEmpty else { throw XCTSkip("no dev-stack Lidarr passed in") }
        guard let host = URLComponents(string: lidarrURL)?.host, ["127.0.0.1", "localhost"].contains(host) else {
            XCTFail("Refusing a non-local Lidarr (\(lidarrURL))")
            throw XCTSkip("non-local Lidarr")
        }
        let app = try launchSignedIn()
        let settings = app.buttons["open-settings"]
        for _ in 0..<3 where !settings.exists {
            app.tabBars.buttons["Library"].tap()
            _ = settings.waitForExistence(timeout: 5)
        }
        settings.tap()
        let requests = app.buttons["settings-requests"]
        XCTAssertTrue(requests.waitForExistence(timeout: 10))
        requests.tap()
        app.buttons["settings-connect-lidarr"].tap()
        let address = app.textFields["lidarr-address"]
        XCTAssertTrue(address.waitForExistence(timeout: 10))
        address.tap()
        address.typeText(lidarrURL)
        let apiKey = app.secureTextFields["lidarr-api-key"]
        apiKey.tap()
        apiKey.typeText(key)
        app.buttons["lidarr-connect"].tap()
        let version = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Version")).firstMatch
        XCTAssertTrue(version.waitForExistence(timeout: 20))
        app.buttons["Done"].firstMatch.tap()

        let toggle = app.switches["settings-allow-changes"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        if toggle.value as? String != "1" { toggle.switches.firstMatch.exists ? toggle.switches.firstMatch.tap() : toggle.tap() }
        XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == '1'"), object: toggle)],
                                     timeout: 5) == .completed, "changes allowed")
        let provision = app.buttons["settings-provision"]
        XCTAssertTrue(provision.waitForExistence(timeout: 10))
        for _ in 0..<20 where !provision.isEnabled { usleep(200_000) }
        provision.tap()
        let setUp = NSPredicate(format: "label CONTAINS 'Done'")
        XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: setUp, object: provision)], timeout: 30) == .completed,
                      "Magpie is set up in Lidarr")
        let root = app.buttons["settings-root"]
        if root.waitForExistence(timeout: 5) {
            root.tap()
            let library = app.buttons["/music/library"]
            XCTAssertTrue(library.waitForExistence(timeout: 5))
            library.tap()
        }
        // R18 + R20: Add with my defaults, as the test needs it.
        let mine = app.switches["settings-add-with-my-defaults"]
        for _ in 0..<6 where !mine.isHittable { app.swipeUp() }
        XCTAssertTrue(mine.exists, "Settings › New music has Add with my defaults")
        if (mine.value as? String == "1") != withMyDefaults { mine.switches.firstMatch.exists ? mine.switches.firstMatch.tap() : mine.tap() }
        XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", withMyDefaults ? "1" : "0"), object: mine)], timeout: 5) == .completed)
        app.navigationBars.buttons.firstMatch.tap()   // › Settings
        app.buttons["settings-done"].tap()

        let artists = app.buttons["library-artists"]
        XCTAssertTrue(artists.waitForExistence(timeout: 10))
        artists.tap()
        let aurora = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Aurora Field'")).firstMatch
        XCTAssertTrue(aurora.waitForExistence(timeout: 15))
        aurora.tap()
        let status = app.descendants(matching: .any)["artist-lidarr-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 20))
        XCTAssertTrue(status.label.contains("Not in Lidarr"), status.label)
        return app
    }

    /// P3 (re-review N1) with R18 + R20: "Add to your library" with Add with my defaults on is one confirmation naming
    /// the artist and the defaults in one line, and the confirmed choice reaches the add. The dev library has no
    /// visible artist with a real MusicBrainz id that Lidarr could add (its only real one, Judie Tzuke, has just a
    /// missing song, which Navidrome hides), so Aurora Field's fixture MBID is used: Lidarr's lookup can't find it,
    /// the add stops before any write (the release types' profile is made only after the lookup), and the error line
    /// proves the confirmed choice arrived. The real add is covered by ArtistAddIT on the same dev Lidarr.
    @MainActor func testArtistAddConfirmationReachesTheAdd() throws {
        let app = try openAuroraWithLidarr(withMyDefaults: true)
        let add = app.buttons["artist-lidarr-add"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        XCTAssertEqual(add.label, "Add to your library")
        add.tap()
        XCTAssertTrue(app.staticTexts["Add Aurora Field to your library?"].waitForExistence(timeout: 5),
                      "one confirmation names the artist")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Their albums and EPs \u{00B7} Lossless'"))
                        .firstMatch.exists, "with the defaults in one line")
        attachScreenshot(app, "artist-add-confirmation")
        let confirm = app.buttons.matching(NSPredicate(format: "label == 'Add to your library' AND identifier != 'artist-lidarr-add'")).firstMatch
        confirm.tap()
        let error = app.descendants(matching: .any)["artist-lidarr-error"]
        XCTAssertTrue(error.waitForExistence(timeout: 30), "the confirmed choice reached the add (Lidarr can't find the fixture MBID)")
        attachScreenshot(app, "artist-add-result")
    }

    /// R18 + R20 with Add with my defaults off: the Add sheet, preset with When you add an artist (their albums and
    /// EPs, Studio on, Live and Soundtracks off, Lossless), no "Just this album" without an album; the choice reaches
    /// the add, and a failure stays in the sheet.
    @MainActor func testArtistAddSheetWhenAddWithMyDefaultsIsOff() throws {
        let app = try openAuroraWithLidarr(withMyDefaults: false)
        let add = app.buttons["artist-lidarr-add"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.tap()
        let preset = app.buttons["add-what-albumsAndEPs"]
        XCTAssertTrue(preset.waitForExistence(timeout: 5), "the Add sheet")
        XCTAssertTrue(preset.isSelected, "preset with the defaults")
        XCTAssertFalse(app.buttons["add-what-thisAlbum"].exists, "Just this album only with an album")
        attachScreenshot(app, "artist-add-sheet")
        // The sheet opens at half height: the rest is below.
        for id in ["add-studio", "add-live", "add-soundtracks"] {
            let toggle = app.switches[id]
            for _ in 0..<4 where !toggle.isHittable { app.swipeUp() }
            XCTAssertEqual(toggle.value as? String, id == "add-studio" ? "1" : "0", id)
        }
        let start = app.buttons["add-start"]
        for _ in 0..<8 where !start.isHittable { app.swipeUp() }
        XCTAssertTrue(start.isHittable, "the sheet's Add to your library")
        start.tap()
        let error = app.descendants(matching: .any)["add-error"]
        for _ in 0..<15 where !error.exists {
            app.swipeUp()   // the line shows under the button, maybe below the fold
            _ = error.waitForExistence(timeout: 2)
        }
        XCTAssertTrue(error.exists, "the choice reached the add, and its failure stays in the sheet")
        attachScreenshot(app, "artist-add-sheet-result")
        app.buttons["add-cancel"].tap()
        XCTAssertTrue(add.waitForExistence(timeout: 5))
    }

    /// Library › Settings › Requests with the dev Lidarr connected: the G1 switch (off), set-up and change log;
    /// Settings › Scrobbling has Count plays; Library has a Requests row. Reads only: nothing is switched on.
    @MainActor func testSettingsShowLidarrControlsAndRequests() throws {
        let env = ProcessInfo.processInfo.environment
        guard let lidarrURL = env["MAGPIE_IT_LIDARR_URL"], let key = env["MAGPIE_IT_LIDARR_KEY"],
              !lidarrURL.isEmpty, !key.isEmpty else { throw XCTSkip("no dev-stack Lidarr passed in") }
        guard let host = URLComponents(string: lidarrURL)?.host, ["127.0.0.1", "localhost"].contains(host) else {
            XCTFail("Refusing a non-local Lidarr (\(lidarrURL))")
            return
        }
        let app = try launchSignedIn()
        let libraryTab = app.tabBars.buttons["Library"]
        let settings = app.buttons["open-settings"]
        for _ in 0..<3 where !settings.exists {
            libraryTab.tap()
            _ = settings.waitForExistence(timeout: 5)
        }
        XCTAssertFalse(app.buttons["library-requests"].exists, "T21: Requests shows only with Lidarr connected")
        settings.tap()
        // T21b: the top level is a short list of pages; Account & Server, then Requests holds the Lidarr controls.
        let account = app.buttons["settings-account"]
        XCTAssertTrue(account.waitForExistence(timeout: 10))
        attachScreenshot(app, "settings-top")
        account.tap()
        XCTAssertTrue(app.buttons["settings-sign-out"].waitForExistence(timeout: 10))
        attachScreenshot(app, "settings-account")
        app.navigationBars.buttons.firstMatch.tap()   // › Settings
        let requests = app.buttons["settings-requests"]
        XCTAssertTrue(requests.waitForExistence(timeout: 10))
        requests.tap()

        let connect = app.buttons["settings-connect-lidarr"]
        XCTAssertTrue(connect.waitForExistence(timeout: 10))
        connect.tap()
        let address = app.textFields["lidarr-address"]
        XCTAssertTrue(address.waitForExistence(timeout: 10))
        address.tap()
        address.typeText(lidarrURL)
        let apiKey = app.secureTextFields["lidarr-api-key"]
        apiKey.tap()
        apiKey.typeText(key)
        app.buttons["lidarr-connect"].tap()
        let version = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Version")).firstMatch
        XCTAssertTrue(version.waitForExistence(timeout: 20))
        app.buttons["Done"].firstMatch.tap()

        let toggle = app.switches["settings-allow-changes"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        XCTAssertEqual(toggle.value as? String, "0", "G1: changes are off until the owner turns them on")
        XCTAssertTrue(app.buttons["settings-provision"].exists)
        XCTAssertFalse(app.buttons["settings-provision"].isEnabled, "set-up needs changes allowed")
        attachScreenshot(app, "settings-requests")
        let log = app.buttons["settings-change-log"]
        for _ in 0..<4 where !log.isHittable { app.swipeUp() }
        log.tap()
        XCTAssertTrue(app.navigationBars["Lidarr change log"].waitForExistence(timeout: 10))
        app.navigationBars.buttons.firstMatch.tap()   // › New music
        XCTAssertTrue(app.navigationBars["New music"].waitForExistence(timeout: 10))
        app.navigationBars.buttons.firstMatch.tap()   // › Settings
        let scrobbling = app.buttons["settings-scrobbling"]   // T17: Count plays lives in Settings › Scrobbling
        for _ in 0..<4 where !scrobbling.isHittable { app.swipeUp() }
        scrobbling.tap()
        XCTAssertTrue(app.switches["settings-count-plays"].waitForExistence(timeout: 10))
        app.navigationBars.buttons.firstMatch.tap()
        let done = app.buttons["settings-done"]
        XCTAssertTrue(done.waitForExistence(timeout: 10))
        done.tap()
        XCTAssertTrue(app.buttons["library-requests"].waitForExistence(timeout: 10), "Requests shows once Lidarr is connected")

        // T21b: Home's Finish setting up › Review opens Settings on the Requests page (changes are still off).
        let card = app.buttons["finish-setting-up"]
        for _ in 0..<3 where !card.exists {
            app.tabBars.buttons["Home"].tap()
            _ = card.waitForExistence(timeout: 5)
        }
        card.tap()
        XCTAssertTrue(app.switches["settings-allow-changes"].waitForExistence(timeout: 10), "Review lands on Requests")
        XCTAssertTrue(app.navigationBars["New music"].exists)
        app.navigationBars.buttons.firstMatch.tap()   // › Settings
        XCTAssertTrue(app.buttons["settings-account"].waitForExistence(timeout: 10), "Settings lies under Requests")
        app.buttons["settings-done"].tap()
    }

    /// T20: Home in its default order, then Edit Home: Jump back in off, Random albums and Genres on, Most played
    /// dragged to the top; Home follows. Screenshots of each. Preferences outlive a reset launch, so the test starts
    /// and ends with "Reset to default order".
    @MainActor func testHomeLayoutEditor() throws {
        let app = try launchSignedIn()
        let edit = app.buttons["home-edit"]
        let reset = app.buttons["layout-reset"]
        func openEditor() {
            XCTAssertTrue(edit.waitForExistence(timeout: 20))
            for _ in 0..<6 where !edit.isHittable { app.swipeUp() }
            edit.tap()
            XCTAssertTrue(app.switches["layout-jumpBackIn"].waitForExistence(timeout: 10))
        }
        func resetAndClose() {
            for _ in 0..<4 where !reset.exists || !reset.isHittable { app.swipeUp() }
            if reset.isEnabled { reset.tap() }
            XCTAssertFalse(reset.isEnabled, "the default order")
            app.buttons["home-edit-done"].tap()
        }
        openEditor()
        resetAndClose()
        for _ in 0..<6 { app.swipeDown() }
        XCTAssertTrue(app.staticTexts["home-jumpBackIn"].waitForExistence(timeout: 20), "Jump back in shows by default")
        attachScreenshot(app, "home-default")

        openEditor()
        let jump = app.switches["layout-jumpBackIn"]
        attachScreenshot(app, "home-editor")
        func flip(_ id: String) {
            let s = app.switches[id]
            for _ in 0..<4 where !s.isHittable { app.swipeUp() }
            s.switches.firstMatch.exists ? s.switches.firstMatch.tap() : s.tap()
        }
        flip("layout-jumpBackIn")
        XCTAssertEqual(jump.value as? String, "0")
        flip("layout-randomAlbums")
        flip("layout-genres")
        XCTAssertEqual(app.switches["layout-genres"].value as? String, "1")
        // Most played to the top, by its drag handle.
        for _ in 0..<4 where !jump.isHittable { app.swipeDown() }
        let handle = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Reorder' AND label CONTAINS 'Most played'")).firstMatch
        XCTAssertTrue(handle.exists, "drag handle for Most played")
        let top = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Reorder' AND label CONTAINS 'Jump back in'")).firstMatch
        handle.press(forDuration: 0.6, thenDragTo: top)
        attachScreenshot(app, "home-editor-changed")
        for _ in 0..<4 where !reset.exists || !reset.isHittable { app.swipeUp() }
        XCTAssertTrue(reset.isEnabled, "Reset to default order is offered once the order changed")
        app.buttons["home-edit-done"].tap()

        for _ in 0..<6 { app.swipeDown() }
        let most = app.staticTexts["home-mostPlayed"], recent = app.staticTexts["home-recentlyAdded"]
        XCTAssertTrue(app.staticTexts["home-randomAlbums"].waitForExistence(timeout: 20), "Random albums shows")
        XCTAssertFalse(app.staticTexts["home-jumpBackIn"].exists, "Jump back in is hidden")
        XCTAssertTrue(most.exists && recent.exists)
        XCTAssertLessThan(most.frame.minY, recent.frame.minY, "Most played moved above Recently added")
        attachScreenshot(app, "home-reordered")

        openEditor()
        resetAndClose()
    }

    @MainActor private func errorText(_ app: XCUIApplication) -> String {
        let error = app.staticTexts["connect-error"]
        return error.exists ? error.label : "none"
    }

    /// T21: Library › Songs and Favourites open; then Settings › Home & Library › Library: Songs off, Genres dragged to
    /// the top, Recently added off; the Library follows. Screenshots of the editor and the reordered Library.
    /// Preferences outlive a reset launch, so the test starts and ends at the defaults.
    @MainActor func testLibraryLayoutEditor() throws {
        // Restores the layout if this test fails half-way (hidden Songs would break the next test).
        addTeardownBlock { @MainActor [weak self] in
            guard self?.testRun?.hasSucceeded == false else { return }
            let reset = XCUIApplication()
            reset.launchArguments = ["-MagpieUITesting", "YES", "-MagpieResetLayouts", "YES", "-MagpieNetwork", "wifi"]
            reset.launch()
            reset.terminate()
        }
        let app = try launchSignedIn()
        let libraryTab = app.tabBars.buttons["Library"]
        let settings = app.buttons["open-settings"]
        for _ in 0..<3 where !settings.exists {
            libraryTab.tap()
            _ = settings.waitForExistence(timeout: 5)
        }
        let reset = app.buttons["layout-reset"]
        let recent = app.switches["layout-recently-added"]
        func flip(_ s: XCUIElement) {
            for _ in 0..<4 where !s.isHittable { app.swipeUp() }
            s.switches.firstMatch.exists ? s.switches.firstMatch.tap() : s.tap()
        }
        func openEditor() {
            XCTAssertTrue(settings.waitForExistence(timeout: 10))
            settings.tap()
            let hub = app.buttons["settings-home-library"]
            XCTAssertTrue(hub.waitForExistence(timeout: 10))
            for _ in 0..<4 where !hub.isHittable { app.swipeUp() }
            hub.tap()
            let library = app.buttons["settings-library-layout"]
            XCTAssertTrue(library.waitForExistence(timeout: 10))
            library.tap()
            XCTAssertTrue(app.switches["layout-songs"].waitForExistence(timeout: 10))
        }
        func resetAndClose() {
            for _ in 0..<4 where !reset.exists || !reset.isHittable { app.swipeUp() }
            if reset.isEnabled { reset.tap() }
            XCTAssertFalse(reset.isEnabled, "the default order")
            if recent.value as? String == "0" { flip(recent) }
            XCTAssertEqual(recent.value as? String, "1")
            app.navigationBars.buttons.firstMatch.tap()   // › Home & Library
            app.navigationBars.buttons.firstMatch.tap()   // › Settings
            app.buttons["settings-done"].tap()
        }
        openEditor()
        resetAndClose()

        // Songs and Favourites, at the defaults.
        let songs = app.buttons["library-songs"]
        XCTAssertTrue(songs.waitForExistence(timeout: 10))
        songs.tap()
        XCTAssertTrue(app.buttons["song-0"].waitForExistence(timeout: 15), "Songs lists the dev library's songs")
        app.navigationBars.buttons.firstMatch.tap()
        let favourites = app.buttons["library-favourites"]
        XCTAssertTrue(favourites.waitForExistence(timeout: 10))
        favourites.tap()
        XCTAssertTrue(app.navigationBars["Favourites"].waitForExistence(timeout: 10))
        app.navigationBars.buttons.firstMatch.tap()

        openEditor()
        attachScreenshot(app, "library-editor")
        flip(app.switches["layout-songs"])
        XCTAssertEqual(app.switches["layout-songs"].value as? String, "0")
        flip(recent)
        XCTAssertEqual(recent.value as? String, "0")
        let handle = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Reorder' AND label CONTAINS 'Genres'")).firstMatch
        let top = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Reorder' AND label CONTAINS 'Playlists'")).firstMatch
        // Back to the top until both handles are on screen (a fixed four swipes sometimes left them under the bar).
        for _ in 0..<8 where !(handle.exists && handle.isHittable && top.exists && top.isHittable) { app.swipeDown() }
        XCTAssertTrue(handle.waitForExistence(timeout: 5) && handle.isHittable, "drag handle for Genres")
        XCTAssertTrue(top.isHittable, "drag handle for Playlists")
        handle.press(forDuration: 0.6, thenDragTo: top)
        attachScreenshot(app, "library-editor-changed")
        for _ in 0..<4 where !reset.exists || !reset.isHittable { app.swipeUp() }
        XCTAssertTrue(reset.isEnabled, "Reset to default order is offered once the order changed")
        app.navigationBars.buttons.firstMatch.tap()
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["settings-done"].tap()

        let genres = app.buttons["library-genres"], playlists = app.buttons["library-playlists"]
        XCTAssertTrue(genres.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["library-songs"].exists, "Songs is hidden")
        XCTAssertFalse(app.staticTexts["library-recently-added"].exists, "the Recently added grid is off")
        XCTAssertLessThan(genres.frame.minY, playlists.frame.minY, "Genres moved above Playlists")
        attachScreenshot(app, "library-reordered")

        openEditor()
        resetAndClose()
        XCTAssertTrue(app.buttons["library-songs"].waitForExistence(timeout: 10))
    }
}

private extension XCUIElement {
    /// Replaces a search field's text.
    func clearAndType(_ text: String) {
        if let current = value as? String, !current.isEmpty, current != placeholderValue {
            typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        typeText(text)
    }
}
