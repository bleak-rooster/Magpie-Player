import AurralKit
import Foundation
import LidarrKit
import ListenBrainzKit
import MagpieCore
import MagpieTestSupport
import NavidromeKit
import os
import Requests
import Search
import Testing
@testable import Magpie

private let lidarrBase = URL(string: "http://192.168.1.2:8686")!
private let groupMBID = MBID("9d2f7a51-3b0c-4c1e-8f7e-2a0b1c3d4e5f")!
private let firstTrack = MBID("5e0c3c2a-1111-4a6e-9d2c-7b1a2f3e4d51")!
private let releaseMBID = MBID("b5cdfb5f-35a5-4bc5-bbca-57839a71813a")!

/// Round 15 C3 (owner item 6, D135, D136, D139): Try and Add to library on outside songs and albums, in the app against
/// a mock Navidrome and StubAurral 2.13: the gating, the words, the status lines, the album Try and Keep on arrival.
@MainActor @Suite(.serialized) final class LibraryFindsAppTests {
    let tmp = FileManager.default.temporaryDirectory.appending(path: "LibraryFindsAppTests-\(UUID().uuidString)")
    let store = SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.tests.\(UUID().uuidString)"))
    let suite = "LibraryFindsAppTests.\(UUID().uuidString)"
    lazy var defaults = UserDefaults(suiteName: suite)!
    let transport = Round14Routing()
    let nav = PlaylistsNavidrome()
    let aurralStore = MemoryAurralStore()

    deinit {
        store.clear()
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: tmp)
    }

    func model(lidarr: Bool = true) async throws -> AppModel {
        transport.aurral.useAurral213()
        nav.install(on: transport.navidrome)
        let lidarrStore = MemoryLidarrStore()
        if lidarr { try lidarrStore.save(LidarrConnection(base: lidarrBase, apiKey: "dev-key")) }
        let model = AppModel(store: store, lidarrStore: lidarrStore, tokenStore: MemoryTokenStore(),
                             aurralStore: aurralStore, matchIndexDirectory: nil, dataDirectory: tmp, transport: transport,
                             probeTransport: transport, engine: FakeEngine(), previewTransport: transport, defaults: defaults,
                             systemNowPlaying: false, notifications: false, network: FakeNetwork(.wifi),
                             audioFetcher: FakeFetcher())
        model.aurralFeeds.phoneRegion = { nil }
        try await model.signIn(urls: [URL(string: "http://192.168.1.2:4533")!], username: "admin", password: "pw")
        _ = try await model.connectAurral(base: transport.aurral.base, username: StubAurral.defaultUsername,
                                          password: StubAurral.defaultPassword)
        return model
    }

    private var harbour: OutsideSong {
        OutsideSong(title: "Harbour Lights", artist: "Stub Arrows", album: "Harbour Lights", duration: 196,
                    deezerAlbumId: "3136556", previewId: "3135556")
    }

    private func catalog(_ model: AppModel) {
        model.outsideCatalogStore = OutsideCatalog(releaseGroups: { _ in [] }, releases: { _ in
            [MBReleaseDetail(id: releaseMBID, title: "Harbour Lights", date: "2024", status: "Official",
                             tracks: [MBTrack(recording: firstTrack, title: "Harbour Lights", length: 196)])]
        })
    }

    /// Try usable: Allow changes on, Magpie set up in Lidarr, a main root.
    private func available(_ model: AppModel) {
        model.changesAllowed = true
        model.lidarrSetup?.fastStartProfileId = 4
        model.lidarrSetup?.findsMetadataProfileId = 3
        model.lidarrSetup?.magpieTagId = 1
        model.lidarrSetup?.rootFolderPath = "/music/library"
    }

    private func request(library: Bool = false, trial: Bool = false, find: Bool = true,
                         state: RequestState = .ready) -> MagpieRequest {
        var r = MagpieRequest(recording: ExternalRecording(recordingMBID: firstTrack, title: "Harbour Lights",
                                                           artist: "Stub Arrows", duration: 196, source: .lidarr),
                              tier: .standard, createdAt: Date())
        r.state = state
        r.songId = "f1"
        r.addToLibrary = library
        r.askedAsTry = trial
        r.plan = Plan(recordingMBID: firstTrack, releaseGroupMBID: groupMBID, artistMBID: firstTrack, lidarrArtistId: 4,
                      mode: find ? .finds : .fallback)
        return r
    }

    // MARK: - Gating (D139)

    @Test func theActionsAreHiddenWithoutLidarrAndExplainedWithChangesOff() async throws {
        let none = try await model(lidarr: false)
        #expect(none.libraryActions == .hidden && !none.outsideSongMenuAvailable)
        none.signOut()
        let model = try await model()
        defer { model.signOut() }
        #expect(!model.changesAllowed)
        guard case .explained(let why) = model.libraryActions else { Issue.record("explained"); return }
        #expect(why == TryAvailability.changesOff.message)
        let before = transport.navidrome.requests.count
        await model.addToLibrary(harbour)
        #expect(model.libraryEdits.notice?.text == why, "a tap says why; never a dead button")
        await model.addAlbumToLibrary(OutsideAlbumRef(title: "Harbour Lights", artist: "Stub Arrows"))
        #expect(model.libraryEdits.notice?.text == why)
        model.libraryEdits.notice = nil
        await model.tryOutside(harbour)
        #expect(model.libraryEdits.notice?.text == why && model.songActions.trying == nil, "Try says why too, reading nothing")
        #expect(transport.navidrome.requests.dropFirst(before).allSatisfy { ($0.httpMethod ?? "GET") == "GET" },
                "nothing written")
    }

    @Test func withChangesOffTheLibraryQualityIsNeverMade() async throws {
        let model = try await model()
        defer { model.signOut() }
        model.lidarrSetup?.fastStartProfileId = 4
        await #expect(throws: RequestRunner.TryError.changesOff) { try await model.ensureLibraryQuality() }
        #expect(model.lidarrSetup?.losslessPreferredProfileId == nil)
        #expect(!transport.navidrome.requests.contains { $0.url?.path.hasSuffix("/qualityprofile") == true && $0.httpMethod == "POST" })
    }

    // MARK: - Try on an album (D139)

    @Test func tryOnAnAlbumResolvesItThroughTheServerThenOpensTheTrialTry() async throws {
        let model = try await model()
        defer { model.signOut() }
        catalog(model)
        available(model)
        #expect(model.libraryActions == .available)
        await model.tryOutsideAlbum(OutsideAlbumRef(title: "Harbour Lights", artist: "Stub Arrows"))
        let target = try #require(model.songActions.trying)
        #expect(target.albumGroup == MBID(StubAurralDiscover.releaseGroup) && target.recording.recordingMBID == firstTrack)
        #expect(target.intent == .trial, "a trial: Keep or Reject")
        #expect(transport.aurral.asked.contains { $0.hasPrefix("GET /api/discover/editorial/links") })
    }

    @Test func anAlbumThatCantBeMatchedSaysSo() async throws {
        let model = try await model()
        defer { model.signOut() }
        model.outsideCatalogStore = OutsideCatalog(releaseGroups: { _ in [] }, releases: { _ in [] })
        available(model)
        await model.tryOutsideAlbum(OutsideAlbumRef(title: "Nothing Like It", artist: "Stub Arrows"))
        #expect(model.songActions.trying == nil)
        #expect(model.songActions.unmatchedAlbum?.title == "Nothing Like It")
    }

    // MARK: - Kept on arrival (D135)

    @Test func anArrivedFindForTheLibraryIsKeptOnce() async throws {
        let model = try await model()
        defer { model.signOut() }
        let mine = request(library: true)
        model.requests = [mine, request(trial: true)]
        model.songActions.requestsLoaded = true
        await model.evaluateLibraryAdds()
        #expect(model.songActions.keepAttempts == [mine.id], "only the one asked into the library")
        await model.evaluateLibraryAdds()
        #expect(model.songActions.keepAttempts.filter { $0 == mine.id }.count <= 2)
        #expect(!model.songActions.keepAttempts.contains(model.requests[1].id), "a trial is never kept from here")
    }

    // MARK: - Status (D136)

    @Test func theRowsSayWhereItStands() async throws {
        let model = try await model()
        defer { model.signOut() }
        #expect(model.libraryStatus(for: harbour) == nil)
        model.requests = [request(library: true, state: .downloading(progress: 0.4))]
        #expect(model.libraryStatus(for: harbour) == "Coming \u{00B7} 40%")
        #expect(model.libraryStatus(forAlbum: groupMBID) == "Coming \u{00B7} 40%")
        model.requests = [request(library: true, state: .searching)]
        #expect(model.libraryStatus(for: harbour) == "Coming")
        let trial = request(trial: true)
        model.requests = [trial]
        let until = try #require(model.trialEnds(trial))
        #expect(model.libraryStatus(for: harbour)
                == "On trial \u{00B7} until \(until.formatted(.dateTime.day().month(.abbreviated)))")
        model.requests = [request(library: true, find: false)]
        #expect(model.libraryStatus(for: harbour) == "In your library")
        let failed = request(library: true, state: .failed(reason: .noRelease))
        model.requests = [failed]
        #expect(model.libraryStatus(for: harbour) == "Couldn\u{2019}t bring it in")
        #expect(model.stoppedRequest(for: harbour)?.id == failed.id, "Retry")
    }

    @Test func theWordsNeverNameAService() {
        let words = [LibraryFindsCopy.tryIt, LibraryFindsCopy.tryNote, LibraryFindsCopy.addToLibrary, LibraryFindsCopy.addNote,
                     LibraryFindsCopy.addAlbumNote, LibraryFindsCopy.confirmTitle, LibraryFindsCopy.unmatchedAlbumTitle,
                     LibraryFindsCopy.unmatchedAlbumMessage, LibraryFindsCopy.singlesTitle,
                     LibraryFindsCopy.singlesMessage(artist: "A", song: "S"), LibraryFindsCopy.singlesFailed,
                     LibraryFindsCopy.singlesFailedNeedsLook, LibraryFindsCopy.singlesUndone, LibraryFindsCopy.onTrialHeader,
                     LibraryFindsCopy.kept, LibraryFindsCopy.rejected, LibraryFindsCopy.rejectMessage,
                     LibraryFindsCopy.rejectRefused, LibraryFindsCopy.trialNeedsLook,
                     LibraryFindsCopy.comesWithAlbum("X"), LibraryFindsCopy.added("X"), LibraryFindsCopy.trying("X"),
                     LibraryFindsCopy.retry]
            + [LibraryAdds.Status.inLibrary, .onTrial, .coming(0.5), .coming(nil), .couldntBringIn].map { LibraryFindsCopy.status($0) }
        for w in words {
            #expect(!w.isEmpty && !w.localizedCaseInsensitiveContains("aurral") && !w.localizedCaseInsensitiveContains("lidarr"), "\(w)")
        }
        #expect(LibraryFindsCopy.comesWithAlbum("Lowlands") == "This song comes with the album \u{201C}Lowlands\u{201D}.")
        #expect(LibraryFindsCopy.singlesMessage(artist: "Low", song: "Words")
                == "Singles will be listed for Low. Only \u{201C}Words\u{201D} downloads; nothing else changes.")
    }

    // MARK: - Library trials in Finds (D147)

    private func libraryTrial() -> MagpieRequest {
        var r = request(trial: true, find: false)
        r.trialExpiresAt = Date().addingTimeInterval(14 * 86_400)
        r.albumId = 33
        return r
    }

    @Test func aLibraryTrialIsListedInFindsAndTheCarWithItsDate() async throws {
        let model = try await model()
        defer { model.signOut() }
        #expect(model.libraryTrials.isEmpty && !model.libraryRows.contains(.finds), "no Finds folder, no trials: no Finds row")
        let trial = libraryTrial()
        model.requests = [trial, request(trial: true, find: false, state: .downloading(progress: 0.2))]
        #expect(model.libraryTrials.map(\.id) == [trial.id], "only arrived ones")
        #expect(model.libraryRows.contains(.finds), "Finds shows for its trials")
        #expect(model.trialEnds(trial) == trial.trialExpiresAt)
        #expect(model.carPlayFinds?.finds.map(\.song.title) == ["Harbour Lights"])
        var kept = trial
        kept.trialKept = true
        model.requests = [kept]
        #expect(model.libraryTrials.isEmpty, "kept: no longer on trial")
    }

    /// Reject is proven before anything changes: with Allow changes off, or a trial the runner can't prove, no playlist
    /// is touched and nothing is written.
    @Test func aRejectThatCantGoChangesNoPlaylist() async throws {
        let model = try await model()
        defer { model.signOut() }
        let trial = libraryTrial()
        model.requests = [trial]
        #expect(await model.rejectLibraryTrial(trial) == TryAvailability.changesOff.message)
        model.changesAllowed = true
        #expect(await model.rejectLibraryTrial(trial) == LibraryFindsCopy.rejectRefused)
        #expect(nav.updates.isEmpty && model.letGo.jobs.isEmpty, "no playlist touched")
        #expect(transport.navidrome.requests.allSatisfy { ($0.httpMethod ?? "GET") == "GET" || $0.url?.path.hasSuffix("/auth/login") == true },
                "nothing written")
    }

    // MARK: - Review fixes

    /// M1: when what comes with the song can't be checked, nothing is sent: a retryable message instead.
    @Test func whenWhatComesCantBeCheckedNothingIsSent() async throws {
        let model = try await model()
        defer { model.signOut() }
        catalog(model)
        available(model)
        let song = OutsideSong(title: "Harbour Lights", artist: "Stub Arrows", album: "Harbour Lights", duration: 196,
                               artistMBID: MBID("a74b1b7f-71a5-4011-9441-d0b5e4122711"), releaseGroupMBID: groupMBID, recordingMBID: firstTrack)
        await model.addToLibrary(song)   // MusicBrainz isn't reachable on the mock: the preview fails
        #expect(model.libraryEdits.notice?.text == LibraryFindsCopy.couldntCheck)
        #expect(model.requests.isEmpty && model.songActions.libraryConfirm == nil)
        #expect(transport.navidrome.requests.allSatisfy { ($0.httpMethod ?? "GET") == "GET" || $0.url?.path.hasSuffix("/auth/login") == true })
    }

    /// M8: a trial whose ledger entry was superseded (a later Try or Add of the album) shows no Keep or Reject.
    @Test func aSupersededTrialIsNotListed() async throws {
        let model = try await model()
        defer { model.signOut() }
        let trial = libraryTrial()
        model.requests = [trial]
        model.songActions.openTrialAlbums = [33]
        #expect(model.libraryTrials.map(\.id) == [trial.id])
        model.songActions.openTrialAlbums = []
        #expect(model.libraryTrials.isEmpty)
    }

    /// M8: an album known only by name (Trending's) shows where it stands.
    @Test func anAlbumKnownByNameShowsItsStatus() async throws {
        let model = try await model()
        defer { model.signOut() }
        var r = request(library: true, find: false, state: .downloading(progress: 0.5))
        r.albumTarget = groupMBID
        r.albumTitle = "Harbour Lights"
        model.requests = [r]
        #expect(model.libraryStatus(forAlbumTitled: "harbour lights", artist: "Stub Arrows") == "Coming \u{00B7} 50%")
        #expect(model.libraryStatus(for: OutsideAlbumRef(title: "Harbour Lights", artist: "Stub Arrows")) == "Coming \u{00B7} 50%")
        #expect(model.libraryStatus(forAlbumTitled: "Other", artist: "Stub Arrows") == nil)
    }

    /// M5: the UI-test hooks act only on a dev server on this machine.
    @Test func theUITestHooksNeedALoopbackServer() async throws {
        let model = try await model()
        defer { model.signOut() }
        #expect(!model.signedInToLoopback, "the mock server is 192.168.1.2")
        let defaults = UserDefaults(suiteName: "hooks-\(UUID().uuidString)")!
        defaults.set("YES", forKey: "MagpieUITesting")
        defaults.set("f1", forKey: "MagpieUITestLetGo")
        defaults.set("f1", forKey: "MagpieUITestLibraryTrial")
        await model.runUITestLetGoIfAsked(defaults)
        await model.seedUITestLibraryTrialIfAsked(defaults)
        #expect(model.letGo.jobs.isEmpty && model.requests.isEmpty && nav.updates.isEmpty)
    }

    // MARK: - Re-review R2, m3

    /// R2: owner defaults of Albums only, and an EP asked for: the add's types list the EP; a kind that can't be listed
    /// is refused before anything is sent.
    @Test func aNewArtistsAddListsTheReleaseAskedFor() async throws {
        let types = try #require(AppModel.libraryTypes(defaults: ReleaseTypes(kinds: .albums), primaryType: "EP", secondaryTypes: []))
        #expect(types.includes(albumType: "EP", secondaryTypes: []) && types.includes(albumType: "Album", secondaryTypes: []))
        let model = try await model()
        defer { model.signOut() }
        available(model)
        let before = transport.navidrome.requests.count
        let recording = ExternalRecording(recordingMBID: firstTrack, title: "Harbour Lights", artist: "Stub Arrows", source: .lidarr)
        await model.sendToLibrary(recording, album: groupMBID, title: "Harbour Lights",
                                  preview: .newArtist(title: "Harbour Lights", isAlbum: false, primaryType: "Broadcast", secondaryTypes: []))
        #expect(model.libraryEdits.notice?.text == LibraryFindsCopy.refusedKind)
        #expect(transport.navidrome.requests.dropFirst(before).allSatisfy { ($0.httpMethod ?? "GET") == "GET" })
    }

    /// m3: the change log line a switch saved names its artist, profile and following (for "Put back").
    @Test func aSwitchLineSaysWhatWasSaved() {
        let line = ChangeLogEntry(date: Date(), method: "NOTE", path: "/magpie",
                                  bodySummary: LidarrWriteGate.singlesNote(artistId: 20, metadataProfileId: 5, monitorNewItems: "all"))
        let saved = ChangeLogView.singlesSaved(line)
        #expect(saved?.artistId == 20 && saved?.profileId == 5 && saved?.follow == "all")
        #expect(ChangeLogView.singlesSaved(ChangeLogEntry(date: Date(), method: "PUT", path: "/x", bodySummary: "")) == nil)
    }

    // MARK: - Re-review 2

    /// N1: "Put back" only on this Lidarr's lines, for artists its quarantined journal named.
    @Test func putBackIsOfferedOnlyOnThisLidarrsLostArtists() {
        func line(_ artist: Int, _ instance: String?) -> ChangeLogEntry {
            ChangeLogEntry(date: Date(), method: "NOTE", path: "/magpie",
                           bodySummary: LidarrWriteGate.singlesNote(artistId: artist, metadataProfileId: 5, monitorNewItems: "all",
                                                                    instance: instance))
        }
        let lines = [line(20, "lidarr-a"), line(20, "lidarr-b"), line(21, "lidarr-a"), line(22, nil)]
        #expect(AppModel.putBackArtists(lines, lost: [20, 22], instance: "lidarr-a") == [20], "lost here, on this Lidarr's line")
        #expect(AppModel.putBackArtists(lines, lost: [], instance: "lidarr-a").isEmpty, "after a sign-in: nothing lost")
        #expect(AppModel.putBackArtists(lines, lost: [20], instance: "lidarr-c").isEmpty, "another Lidarr")
        #expect(ChangeLogView.singlesSaved(lines[0])?.instance == "lidarr-a")
    }

    /// R2 status: a release with no Official release is refused before anything is sent.
    @Test func aNonOfficialReleaseIsRefused() async throws {
        let model = try await model()
        defer { model.signOut() }
        available(model)
        let before = transport.navidrome.requests.count
        let recording = ExternalRecording(recordingMBID: firstTrack, title: "Harbour Lights", artist: "Stub Arrows", source: .lidarr)
        let accepted = await model.sendToLibrary(recording, album: groupMBID, title: "Harbour Lights",
                                                 preview: .newArtist(title: "Bootleg", isAlbum: true, primaryType: "Album",
                                                                     secondaryTypes: [], official: false))
        #expect(!accepted && model.libraryEdits.notice?.text == LibraryFindsCopy.refusedKind)
        #expect(transport.navidrome.requests.dropFirst(before).allSatisfy { ($0.httpMethod ?? "GET") == "GET" })
    }
}
