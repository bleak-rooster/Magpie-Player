import Foundation
@testable import LidarrKit
import MagpieCore
import MagpieTestSupport
import Requests
import Testing
@testable import Magpie

private let ok = Data(#"{"subsonic-response":{"status":"ok","version":"1.16.1"}}"#.utf8)
private let loginJSON = Data(#"""
{"id":"u1","isAdmin":true,"name":"Admin","subsonicSalt":"salt","subsonicToken":"tok","token":"jwt","username":"jordan"}
"""#.utf8)
private let home = URL(string: "http://192.168.1.2:4533")!
private let lidarrBase = URL(string: "http://192.168.1.2:8686")!
private let lidarrScope = LidarrClient(base: lidarrBase, apiKey: "key", transport: MockTransport()).instanceScope

/// Round 24 (owner, 2026-11-08, D237–D244): "Change what's monitored" and "Clean up unmatched songs" in the app: the plan's
/// words, Keep as the default answer, the More menu's items only where they can work (all four setups), the switch off
/// by default for each Lidarr, and what the owner keeps read from favourites, playlists and the phone.
@MainActor @Suite(.serialized) struct MonitoringChangeAppTests {
    typealias Copy = MonitoringCopy
    typealias Items = ArtistMonitoringPresentation

    @Test func theCopyIsThePlans() {
        #expect(Copy.change == "Change what\u{2019}s monitored")
        #expect(Copy.cleanUp == "Clean up unmatched songs")
        #expect(Copy.custom == "Custom (set in Lidarr)")
        #expect(Copy.prompt(albums: 6, songs: 41, bytes: 1_200_000_000)
                == "These stop being monitored: 6 albums, 41 songs (1.2 GB). Delete them now, or keep them?")
        #expect(Copy.prompt(albums: 1, songs: 1, bytes: 5_000_000)
                == "These stop being monitored: 1 album, 1 song (5 MB). Delete them now, or keep them?")
        #expect(Copy.deleteThem == "Delete them")
        #expect(Copy.keepThem == "Keep them")
        #expect(Copy.confirmDelete(41) == "Delete 41 songs?")
        #expect(Copy.cleanUpMessage(count: 41, artist: "Jordan")
                == "Removes 41 songs by Jordan that you chose not to keep monitoring. Songs you\u{2019}ve favourited or saved to a playlist stay.")
        #expect(Copy.keptFavourite == "Kept because you favourited it")
        #expect(Copy.toggle == "Let Magpie change what Lidarr monitors for my artists")
        // §5: no service named outside Settings, and nothing about where songs come from.
        for text in [Copy.change, Copy.cleanUp, Copy.prompt(albums: 2, songs: 3, bytes: 10), Copy.cleanUpMessage(count: 2, artist: "A"),
                     Copy.keptFavourite, Copy.keptSaved, Copy.done, Copy.pending, Copy.abandoned, Copy.revert, Copy.revertMessage,
                     Copy.stoppedPartway, Copy.stillFinishing, Copy.willBeRemoved, Copy.paused] {
            for word in ["Lidarr", "Navidrome", "Soulseek", "Aurral"] { #expect(!text.contains(word), "\(text)") }
        }
    }

    /// Fix round 1 I4, M4: an unfinished or stopped change is said on the page (resume's outcome is used, not dropped);
    /// a removed song says so in words.
    @Test func anUnfinishedOrStoppedChangeIsSaid() {
        #expect(ArtistMonitoringState.notice(outcome: .pending, current: nil) == .unfinished)
        #expect(ArtistMonitoringState.notice(outcome: .abandoned, current: nil) == .stopped(canRevert: false))
        #expect(ArtistMonitoringState.notice(outcome: .finished, current: nil) == nil)
        #expect(ArtistMonitoringState.notice(outcome: nil, current: nil) == nil)
        #expect(Copy.abandoned.contains("stopped partway"))
        #expect(Copy.willBeRemoved == "Will be removed")
    }

    @Test func reduce_keepIsDefault() {
        #expect(ChangeMonitoringFlow.preferredAnswer == .keep)
        #expect(ReduceChoice.default == .keep)
    }

    /// Hidden without Lidarr, offline, with either switch off, and for an artist that isn't in Lidarr or is a find; the
    /// clean-up only when songs were kept.
    @Test func theMoreMenuItemsInEachSetup() {
        let monitored = ArtistLidarrState.monitored(lidarrId: 20, searching: false)
        #expect(Items.items(lidarr: false, offline: false, changesAllowed: true, monitoringAllowed: true, state: monitored, hasKept: true).isEmpty)
        #expect(Items.items(lidarr: true, offline: true, changesAllowed: true, monitoringAllowed: true, state: monitored, hasKept: true).isEmpty)
        #expect(Items.items(lidarr: true, offline: false, changesAllowed: false, monitoringAllowed: true, state: monitored, hasKept: true).isEmpty)
        #expect(Items.items(lidarr: true, offline: false, changesAllowed: true, monitoringAllowed: false, state: monitored, hasKept: true).isEmpty)
        #expect(Items.items(lidarr: true, offline: false, changesAllowed: true, monitoringAllowed: true, state: nil, hasKept: false).isEmpty)
        #expect(Items.items(lidarr: true, offline: false, changesAllowed: true, monitoringAllowed: true,
                            state: .notInLidarr(mbid: nil), hasKept: false).isEmpty)
        #expect(Items.items(lidarr: true, offline: false, changesAllowed: true, monitoringAllowed: true,
                            state: .find(lidarrId: 20, state: .find), hasKept: true).isEmpty)
        #expect(Items.items(lidarr: true, offline: false, changesAllowed: true, monitoringAllowed: true, state: .unmatched, hasKept: true).isEmpty)
        #expect(Items.items(lidarr: true, offline: false, changesAllowed: true, monitoringAllowed: true, state: monitored, hasKept: false)
                == [.change])
        #expect(Items.items(lidarr: true, offline: false, changesAllowed: true, monitoringAllowed: true,
                            state: .notMonitored(lidarrId: 20, magpieAdded: false), hasKept: true) == [.change, .cleanUp])
        #expect(Items.lidarrId(monitored) == 20)
    }

    /// Favourites, playlists and the phone: any song's recording counts; titles and album titles only for this artist's
    /// songs (loosely: "Jordan feat. Sam" counts as Jordan's).
    @Test func theKeepListComesFromFavouritesPlaylistsAndThePhone() {
        let rec = MBID("99999999-9999-4999-8999-999999999999")!
        func song(_ title: String, _ artist: String, recording: MBID? = nil) -> Song {
            Song(id: title, title: title, artist: artist, album: "X", duration: 100, recordingMBID: recording)
        }
        let list = AppModel.monitoringKeepList(
            artist: "Jordan",
            favourites: [song("Starred Song", "Jordan"), song("Someone Else's", "Other", recording: rec)],
            favouriteAlbums: [Album(id: "a", name: "Kept Album", artist: "Jordan", songCount: 1, duration: 1),
                              Album(id: "b", name: "Not Theirs", artist: "Other", songCount: 1, duration: 1)],
            saved: [song("In A Playlist", "Jordan feat. Sam")],
            onPhone: [song("Downloaded", "JORDAN")])
        #expect(list.keeps(recording: rec.rawValue, title: nil, album: nil))
        #expect(list.keeps(recording: nil, title: "starred song", album: nil))
        #expect(list.keeps(recording: nil, title: "In a Playlist", album: nil))
        #expect(list.keeps(recording: nil, title: "Downloaded", album: nil))
        #expect(list.keeps(recording: nil, title: nil, album: "Kept Album"))
        #expect(!list.keeps(recording: nil, title: "Someone Else's", album: nil))
        #expect(!list.keeps(recording: nil, title: nil, album: "Not Theirs"))
    }

    // MARK: - The switch

    let transport = HostSwitchTransport()
    let store = SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.tests.\(UUID().uuidString)"))
    let lidarrStore = MemoryLidarrStore()
    let gateSuite = "magpie-tests-gate-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: "magpie-tests-\(UUID().uuidString)")!
    let data = FileManager.default.temporaryDirectory.appending(path: "MonitoringChangeAppTests-\(UUID().uuidString)")

    init() {
        let t = transport.inner
        t.stub(pathSuffix: "/rest/ping", body: ok)
        t.stub(method: "POST", pathSuffix: "/auth/login", body: loginJSON)
        t.stub(pathSuffix: "/api/song", body: Data("[]".utf8), headers: ["X-Total-Count": "0"])
        t.stub(pathSuffix: "/api/v1/system/status", body: Data(#"{"version":"3.2.0","instanceName":"Lidarr","authentication":"forms"}"#.utf8))
        t.stub(pathSuffix: "/api/v1/rootfolder", body: Data(#"[{"id":1,"path":"/music"}]"#.utf8))
    }

    /// R24H fix round 4 (D-L2): a cold launch for the background request pass never resumes a monitoring change; the
    /// scene becoming active does.
    @Test func aColdBackgroundPassSendsNoMonitoringWrite() async throws {
        AppModel.MonitoringSwitch.shared.sceneActive = false
        LidarrSetupStore(defaults: defaults).save(LidarrSetup(base: lidarrBase, scope: lidarrScope, fastStartProfileId: 4,
                                                              findsMetadataProfileId: 3, magpieTagId: 1,
                                                              losslessProfileId: 7, rootFolderPath: "/music"))
        let model = AppModel(store: store, lidarrStore: lidarrStore, tokenStore: MemoryTokenStore(), matchIndexDirectory: nil,
                             dataDirectory: data, gateDefaultsSuite: gateSuite, transport: transport, probeTransport: transport,
                             engine: FakeEngine(), defaults: defaults, systemNowPlaying: false, notifications: false)
        defer {
            model.signOut()
            UserDefaults(suiteName: gateSuite)?.removePersistentDomain(forName: gateSuite)
            try? FileManager.default.removeItem(at: data)
        }
        try await model.signIn(urls: [home], username: "jordan", password: "pw")
        _ = try await model.connectLidarr(base: lidarrBase, apiKey: "key")
        await model.setChangesAllowed(true)
        // The switch on, as an earlier session left it (turning it on here would resume by itself).
        UserDefaults(suiteName: gateSuite)?.set(true, forKey: LidarrWriteGate.monitoringChangesKey(scope: lidarrScope))
        // An unfinished change of artist 20, its unmonitor not sent yet.
        let ledger = Ledger(fileURL: Ledger.defaultURL(in: data), instance: lidarrScope)
        let intent = MonitoringIntent(kind: .monitoringChange, artistId: 20, artistMbid: MBID("22222222-2222-4222-8222-222222222222")!,
                                      previousProfileId: 5, targetProfileId: 30,
                                      targetTypes: ReleaseTypes(albums: true, eps: false, singles: false),
                                      unmonitorAlbumIds: [2], createdAt: Date())
        try await ledger.saveIntent(intent)
        // A cold background launch: the runner is built and the pass runs.
        model.rebuildRunner()
        _ = await model.backgroundRequestPass(limit: .seconds(5), submit: { _ in })
        for _ in 0..<50 { await Task.yield() }
        let monitoringWrites = { [transport] in
            transport.inner.requests.filter { r in
                (r.httpMethod ?? "GET") != "GET" && ["/api/v1/album/monitor", "/api/v1/artist/editor", "/api/v1/command"].contains(r.url?.path ?? "")
            }
        }
        #expect(monitoringWrites().isEmpty, "no monitoring write from a background pass")
        #expect(try await ledger.monitoringBook.intents.first?.sending == nil, "nothing was even about to be sent")
        // The scene becoming active resumes it: the intent moves on (marked as sending, or ended by the gate's refusal
        // here, where this fake Lidarr has no artist 20).
        model.monitoringSceneChanged(active: true)
        #expect(await eventually {
            guard let now = try? await ledger.monitoringBook.intents.first else { return false }
            return now.sending != nil || now.step != .saved
        })
        AppModel.MonitoringSwitch.shared.sceneActive = false
    }

    @Test func theSwitchIsOffByDefaultForEachLidarr() async throws {
        LidarrSetupStore(defaults: defaults).save(LidarrSetup(base: lidarrBase, scope: lidarrScope, fastStartProfileId: 4,
                                                              findsMetadataProfileId: 3, magpieTagId: 1,
                                                              losslessProfileId: 7, rootFolderPath: "/music"))
        let model = AppModel(store: store, lidarrStore: lidarrStore, tokenStore: MemoryTokenStore(), matchIndexDirectory: nil,
                             dataDirectory: data, gateDefaultsSuite: gateSuite, transport: transport, probeTransport: transport,
                             engine: FakeEngine(), defaults: defaults, systemNowPlaying: false, notifications: false)
        defer {
            model.signOut()
            UserDefaults(suiteName: gateSuite)?.removePersistentDomain(forName: gateSuite)
            try? FileManager.default.removeItem(at: data)
        }
        #expect(model.monitoringChangesAllowed == false, "no Lidarr: off")
        try await model.signIn(urls: [home], username: "jordan", password: "pw")
        _ = try await model.connectLidarr(base: lidarrBase, apiKey: "key")
        #expect(model.monitoringChangesAllowed == false, "off until the owner turns it on")
        await model.setMonitoringChangesAllowed(true)
        #expect(model.monitoringChangesAllowed)
        let gate = try #require(model.gate)
        #expect(await gate.monitoringChangesEnabled, "the gate reads the same switch")
        #expect(UserDefaults(suiteName: gateSuite)?.bool(forKey: LidarrWriteGate.monitoringChangesKey(scope: lidarrScope)) == true)
        await model.setMonitoringChangesAllowed(false)
        #expect(await gate.monitoringChangesEnabled == false)
        // Fix round 1 I3: disconnecting forgets the switch, so a reconnect starts with it off.
        await model.setMonitoringChangesAllowed(true)
        model.disconnectLidarr()
        #expect(UserDefaults(suiteName: gateSuite)?.object(forKey: LidarrWriteGate.monitoringChangesKey(scope: lidarrScope)) == nil)
        _ = try await model.connectLidarr(base: lidarrBase, apiKey: "key")
        #expect(model.monitoringChangesAllowed == false)
    }
}
