import XCTest

/// Round 15 C3 (owner item 7, D137): a rejected find leaves the owner's playlists, and Magpie says so. Run in Release
/// (TestFlight-equivalent) against the dev Navidrome. The dev stack can't make a real find (Lidarr would need the
/// internet), so the app is launched with `-MagpieUITesting YES -MagpieUITestLetGo <song id>`, which runs the very
/// clean-up a confirmed Not for me runs before the find's files go (D138). The playlist is made here through the
/// Subsonic API with the song in it twice between two others, and deleted afterwards. Guard G0: localhost only.
final class Round15LetGoUITests: XCTestCase {
    private struct Stack { var url: String; var user: String; var password: String }

    private func stack() throws -> Stack {
        let env = ProcessInfo.processInfo.environment
        guard env["MAGPIE_IT"] == "1" else { throw XCTSkip("set MAGPIE_IT=1 (MAGPIE_IT=1 scripts/test-app.sh) to run") }
        guard let url = env["MAGPIE_IT_URL"], let user = env["MAGPIE_IT_USER"], let password = env["MAGPIE_IT_PASSWORD"],
              !url.isEmpty, !user.isEmpty, !password.isEmpty else {
            XCTFail("MAGPIE_IT=1 but the dev stack wasn't passed in")
            throw XCTSkip("missing dev-stack environment")
        }
        guard let host = URLComponents(string: url)?.host, ["127.0.0.1", "localhost"].contains(host) else {
            XCTFail("Refusing to run against a non-local server; the UI test only talks to the dev stack")
            throw XCTSkip("non-local server")
        }
        return Stack(url: url, user: user, password: password)
    }

    /// One Subsonic call to the dev Navidrome as the test user; the answer's `subsonic-response`.
    private func call(_ s: Stack, _ method: String, _ extra: [URLQueryItem]) -> [String: Any]? {
        var c = URLComponents(string: s.url.hasSuffix("/") ? s.url + "rest/\(method)" : s.url + "/rest/\(method)")!
        let hex = s.password.utf8.map { String(format: "%02x", $0) }.joined()
        c.queryItems = [URLQueryItem(name: "u", value: s.user), URLQueryItem(name: "p", value: "enc:" + hex),
                        URLQueryItem(name: "v", value: "1.16.1"), URLQueryItem(name: "c", value: "magpie-uitest"),
                        URLQueryItem(name: "f", value: "json")] + extra
        let done = expectation(description: method)
        var body: Data?
        URLSession.shared.dataTask(with: c.url!) { data, _, _ in body = data; done.fulfill() }.resume()
        wait(for: [done], timeout: 15)
        guard let body, let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        return json["subsonic-response"] as? [String: Any]
    }

    private func playlistSongs(_ s: Stack, _ id: String) -> [String] {
        let list = call(s, "getPlaylist", [URLQueryItem(name: "id", value: id)])?["playlist"] as? [String: Any]
        return (list?["entry"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
    }

    @MainActor func testARejectedFindLeavesItsPlaylistAndMagpieSaysSo() throws {
        let s = try stack()
        continueAfterFailure = false
        // Three songs of the dev library: the "find" and two others.
        let random = call(s, "getRandomSongs", [URLQueryItem(name: "size", value: "3")])?["randomSongs"] as? [String: Any]
        let songs = (random?["song"] as? [[String: Any]] ?? []).compactMap { e -> (String, String)? in
            guard let id = e["id"] as? String, let title = e["title"] as? String else { return nil }
            return (id, title)
        }
        XCTAssertEqual(Set(songs.map(\.0)).count, 3, "the dev library has songs")
        let (findId, findTitle) = songs[0]
        let (a, b) = (songs[1].0, songs[2].0)
        let name = "C3 UI \(UUID().uuidString.prefix(8))"
        let made = call(s, "createPlaylist", [URLQueryItem(name: "name", value: name)]
                        + [a, findId, b, findId].map { URLQueryItem(name: "songId", value: $0) })
        let playlistId = try XCTUnwrap((made?["playlist"] as? [String: Any])?["id"] as? String, "made the playlist")
        addTeardownBlock { [s] in _ = self.call(s, "deletePlaylist", [URLQueryItem(name: "id", value: playlistId)]) }
        XCTAssertEqual(playlistSongs(s, playlistId), [a, findId, b, findId])

        let app = XCUIApplication()
        app.launchArguments = ["-MagpieResetState", "YES", "-MagpieUITesting", "YES", "-MagpieNetwork", "wifi",
                               "-MagpieUITestLetGo", findId]
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

        // The in-app message names the song and the playlist.
        let notice = app.descendants(matching: .any).matching(identifier: "library-notice").firstMatch
        XCTAssertTrue(notice.waitForExistence(timeout: 30), "the message shows")
        let text = notice.label
        attachScreenshot(app, "let-go-message")
        XCTAssertTrue(text.contains("Removed \u{201C}\(findTitle)\u{201D} from"), text)
        XCTAssertTrue(text.contains(name) || text.contains("playlists"), text)

        // The playlist no longer has it (both copies), and the others stay in order.
        XCTAssertEqual(playlistSongs(s, playlistId), [a, b])
    }

    @MainActor private func attachScreenshot(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
