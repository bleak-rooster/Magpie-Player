import Foundation
import MagpieCore
import MagpieTestSupport
import NavidromeKit
import Playback
import Testing
@testable import CarPlayUI
@testable import Magpie

private let ok = Data(#"{"subsonic-response":{"status":"ok","version":"1.16.1"}}"#.utf8)
private let loginJSON = Data(#"""
{"id":"u1","isAdmin":true,"name":"Admin","subsonicSalt":"salt","subsonicToken":"tok","token":"jwt","username":"admin"}
"""#.utf8)
private let home = URL(string: "http://192.168.1.2:4533")!

private func body(_ inner: String) -> Data {
    Data(#"{"subsonic-response":{"status":"ok","version":"1.16.1",\#(inner)}}"#.utf8)
}

private func songsJSON(_ ids: [String]) -> String {
    ids.map { #"{"id":"\#($0)","title":"T\#($0)","artist":"A","album":"B","duration":60}"# }.joined(separator: ",")
}

/// R12: swipe actions (default mapping and customisation, destructive rows), the collection popup's In order /
/// Shuffled, tap to play replacing the queue, and "Ask before replacing the queue" with Replace / Play next / Cancel.
@MainActor @Suite(.serialized) struct QueueActionsTests {
    let transport = HostSwitchTransport()
    let store = SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.tests.\(UUID().uuidString)"))
    let defaults = UserDefaults(suiteName: "QueueActionsTests.\(UUID().uuidString)")!

    init() {
        transport.inner.stub(pathSuffix: "/rest/ping", body: ok)
        transport.inner.stub(method: "POST", pathSuffix: "/auth/login", body: loginJSON)
        transport.inner.stub(pathSuffix: "/rest/scrobble", body: ok)
        transport.inner.stub(pathSuffix: "/api/song", body: Data("[]".utf8), headers: ["X-Total-Count": "0"])
        transport.inner.stub(pathSuffix: "/rest/getAlbum") { request in
            let id = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "id" }?.value ?? ""
            let songs = id == "al2" ? ["c", "d"] : ["a1", "a2", "a3"]
            return .init(status: 200, body: body(#""album":{"id":"\#(id)","name":"Album \#(id)","song":[\#(songsJSON(songs))]}"#), headers: [:])
        }
        transport.inner.stub(pathSuffix: "/rest/getPlaylist",
                             body: body(#""playlist":{"id":"p1","name":"Mix","entry":[\#(songsJSON(["p1", "p2"]))]}"#))
        transport.inner.stub(pathSuffix: "/rest/getArtist",
                             body: body(#""artist":{"id":"ar1","name":"A","album":[{"id":"al1","name":"One"},{"id":"al2","name":"Two"}]}"#))
    }

    private func signedIn() async throws -> AppModel {
        let model = AppModel(store: store, lidarrStore: MemoryLidarrStore(), tokenStore: MemoryTokenStore(),
                             matchIndexDirectory: nil, dataDirectory: nil, transport: transport, probeTransport: transport,
                             engine: FakeEngine(), defaults: defaults, systemNowPlaying: false, notifications: false,
                             network: FakeNetwork(.wifi))
        try await model.signIn(urls: [home], username: "admin", password: "pw")
        return model
    }

    private func tearDown(_ model: AppModel) {
        model.signOut()
        store.clear()
    }

    private func song(_ id: String) -> Song { PlayerTests.song(id) }

    private func ids(_ model: AppModel) -> (current: String?, upNext: [String], rest: [String]) {
        let q = model.player.queue
        let rest = q.currentIndex.map { Array(q.main[($0 + 1)...]) } ?? []
        return (q.current?.song.id, q.upNext.map(\.song.id), rest.map(\.song.id))
    }

    // MARK: - Mapping

    @Test func swipeMappingDefaultsAndCustomisation() {
        let defaults = PlaybackPreferences.defaultValue
        let standard = SwipeLayout.song(right: defaults.swipeRight, left: defaults.swipeLeft)
        #expect(standard == SwipeLayout(leading: [.action(.addToQueue)], trailing: [.action(.playNext)],
                                        leadingFullSwipe: true, trailingFullSwipe: true),
                "swipe right = Add to queue, swipe left = Play next, a full swipe fires either")

        let custom = SwipeLayout.song(right: .download, left: .none)
        #expect(custom.leading == [.action(.download)] && custom.trailing.isEmpty)
        #expect(SwipeLayout.song(right: .none, left: .favourite).leading.isEmpty)

        // A row with its own destructive swipe keeps it on the trailing edge, outermost, with the custom action beside
        // it, and that edge never full-swipes (appraisal §4, R20).
        let playlist = SwipeLayout.song(right: .addToQueue, left: .playNext, destructive: "Remove from playlist")
        #expect(playlist.trailing == [.destructive("Remove from playlist"), .action(.playNext)])
        #expect(!playlist.trailingFullSwipe && playlist.leadingFullSwipe)
        #expect(SwipeLayout.song(right: .addToQueue, left: .none, destructive: "Not for me").trailing == [.destructive("Not for me")])

        #expect(SwipeLayout.collection == SwipeLayout(leading: [.action(.addToQueue)], trailing: [.action(.playNext)],
                                                      leadingFullSwipe: true, trailingFullSwipe: true))
        // The pickers' choices, in the glossary's words.
        #expect(SwipeAction.allCases.map { QueueCopy.title($0) }
                == ["Play next", "Add to queue", "Add to playlist…", "Download", "Favourite", "None"])
    }

    @Test func songSwipesActAndConfirm() async throws {
        let model = try await signedIn()
        defer { tearDown(model) }
        model.play([song("1"), song("2")], startAt: 0)

        model.performSwipe(.addToQueue, on: song("x"))
        #expect(ids(model).rest == ["2", "x"])
        #expect(model.queueActions.toast?.text == "Added to queue")
        model.performSwipe(.playNext, on: song("y"))
        #expect(ids(model).upNext == ["y"])
        #expect(model.queueActions.toast?.text == "Playing next")
        model.performSwipe(.addToPlaylist, on: song("z"))
        #expect(model.queueActions.addingToPlaylist?.songIds == ["z"])
        let before = ids(model)
        model.performSwipe(.none, on: song("w"))
        #expect(ids(model) == before)
    }

    // MARK: - Collections

    @Test func collectionPopupInOrderOrShuffled() async throws {
        let model = try await signedIn()
        defer { tearDown(model) }
        model.play([song("1")], startAt: 0)

        await model.queue(.album("al1"), .end, shuffled: false)
        #expect(ids(model).rest == ["a1", "a2", "a3"], "in order, at the end")
        #expect(model.queueActions.toast?.text == "Added to queue")

        await model.queue(.playlist("p1"), .next, shuffled: false)
        #expect(ids(model).upNext == ["p1", "p2"], "in order, next")
        #expect(model.queueActions.toast?.text == "Playing next")

        // The artist: all their songs, album by album in the artist page's order.
        #expect(try await model.songs(of: .artist("ar1")).map(\.id) == ["a1", "a2", "a3", "c", "d"])

        // Shuffled: the same songs, as one shuffled block.
        model.play([song("1")], startAt: 0)
        var shuffledOnce = false
        for _ in 0..<8 where !shuffledOnce {
            model.play([song("1")], startAt: 0)
            await model.queue(.artist("ar1"), .end, shuffled: true)
            let rest = ids(model).rest
            #expect(Set(rest) == ["a1", "a2", "a3", "c", "d"] && rest.count == 5)
            shuffledOnce = rest != ["a1", "a2", "a3", "c", "d"]
        }
        #expect(shuffledOnce, "shuffled order differs from album order")
    }

    // MARK: - Tap to play

    @Test func tapToPlayReplacesTheQueue() async throws {
        let model = try await signedIn()
        defer { tearDown(model) }
        model.play([song("1"), song("2"), song("3")], startAt: 0)
        model.performSwipe(.playNext, on: song("x"))
        model.play([song("a"), song("b")], startAt: 1)
        #expect(ids(model).current == "b" && ids(model).upNext.isEmpty && ids(model).rest.isEmpty)
        #expect(model.player.queue.main.map(\.song.id) == ["a", "b"], "the queue is the selection, nothing kept")
        #expect(model.queueActions.pendingReplace == nil, "off by default: no question")
    }

    @Test func askBeforeReplacingWithReplacePlayNextCancel() async throws {
        let model = try await signedIn()
        defer { tearDown(model) }
        model.updatePreferences { $0.playback.askBeforeReplacingQueue = true }

        // One song or nothing queued: nothing to protect, so no question.
        model.play([song("1")], startAt: 0)
        #expect(ids(model).current == "1" && model.queueActions.pendingReplace == nil)
        model.play([song("2")], startAt: 0)
        #expect(ids(model).current == "2" && model.queueActions.pendingReplace == nil)

        model.play([song("1"), song("2"), song("3")], startAt: 0)
        // Now three songs are queued (one was the single song; queue of 1 replaced without asking).
        model.play([song("a"), song("b"), song("c")], startAt: 1)
        let pending = try #require(model.queueActions.pendingReplace)
        #expect(pending.queueCount == 3)
        #expect(QueueCopy.replaceTitle == "Replace your queue?" && QueueCopy.replaceMessage(3) == "Your queue has 3 songs.")
        #expect(ids(model).current == "1", "nothing changes until answered")

        // Cancel: the presenter clears it and nothing changes.
        model.queueActions.pendingReplace = nil
        #expect(model.player.queue.main.map(\.song.id) == ["1", "2", "3"])

        // Play next: the tapped song and what follows go ahead of the rest.
        model.play([song("a"), song("b"), song("c")], startAt: 1)
        model.answer(try #require(model.queueActions.pendingReplace), .playNext)
        #expect(ids(model).current == "1" && ids(model).upNext == ["b", "c"] && ids(model).rest == ["2", "3"])
        #expect(model.queueActions.pendingReplace == nil)

        // Replace.
        model.play([song("a"), song("b"), song("c")], startAt: 1)
        model.answer(try #require(model.queueActions.pendingReplace), .replace)
        #expect(ids(model).current == "b" && model.player.queue.main.map(\.song.id) == ["a", "b", "c"])

        // Shuffle asks too (it replaces the queue as well).
        model.shuffle([song("q"), song("r")])
        #expect(model.queueActions.pendingReplace != nil)
    }

    /// The car never asks (D12): CarPlay plays through the player, which replaces at once.
    @Test func carPlayNeverAsks() async throws {
        let model = try await signedIn()
        defer { tearDown(model) }
        model.updatePreferences { $0.playback.askBeforeReplacingQueue = true }
        model.player.play([song("1"), song("2")], startAt: 0)
        let controller = CarPlayController(interfaceController: FakeCarInterface(), library: CarPlayLibraryAdapter(model: model),
                                           player: model.player)
        defer { controller.disconnect() }
        controller.start([song("a"), song("b")], at: 0, shuffled: false)
        #expect(ids(model).current == "a" && model.queueActions.pendingReplace == nil)
    }
}
