import Foundation
import MagpieCore
import MagpieTestSupport
import Requests
import Search
import Testing
@testable import Magpie

private let t0 = Date(timeIntervalSince1970: 1_900_000_000)
private func mb(_ n: Int) -> MBID { MBID(String(format: "00000000-0000-4000-8000-%012d", n))! }
private let artistMBID = mb(1)
private let rgAlbum = mb(10)
private let rgLive = mb(11)
private let rgEP = mb(12)
private let releaseOriginal = mb(20)
private let releaseDeluxe = mb(21)
private let rec1 = mb(100)
private let rec2 = mb(101)

/// R19: the outside artist and album pages in the app (MusicBrainz is a stub; G0).
@MainActor @Suite(.serialized) struct OutsidePagesAppTests {
    let transport = HostSwitchTransport()
    let store = SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.tests.\(UUID().uuidString)"))
    let defaults = UserDefaults(suiteName: "magpie-tests-\(UUID().uuidString)")!
    let gateSuite = "magpie-tests-gate-\(UUID().uuidString)"

    init() {
        transport.inner.stub(pathSuffix: "/ws/2/release") { request in
            let query = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems ?? []
            let body: String
            if query.contains(where: { $0.name == "artist" }) {
                func group(_ id: MBID, _ title: String, _ type: String, _ secondary: [String], _ date: String) -> String {
                    let sec = secondary.map { "\"\($0)\"" }.joined(separator: ",")
                    return #"{"id":"\#(mb(900).rawValue)","status":"Official","release-group":{"id":"\#(id.rawValue)","title":"\#(title)","primary-type":"\#(type)","secondary-types":[\#(sec)],"first-release-date":"\#(date)"}}"#
                }
                body = #"{"release-count":3,"releases":[\#(group(rgLive, "Live at Home", "Album", ["Live"], "2021")),\#(group(rgAlbum, "Continuum", "Album", [], "2019-03-15")),\#(group(rgEP, "Drift EP", "EP", [], "2018"))]}"#
            } else {
                func release(_ id: MBID, _ title: String, _ date: String, _ tracks: [(MBID, String)]) -> String {
                    let list = tracks.enumerated().map { i, t in
                        #"{"position":\#(i + 1),"title":"\#(t.1)","length":60000,"recording":{"id":"\#(t.0.rawValue)"}}"#
                    }.joined(separator: ",")
                    return #"{"id":"\#(id.rawValue)","title":"\#(title)","status":"Official","date":"\#(date)","media":[{"position":1,"tracks":[\#(list)]}]}"#
                }
                body = #"{"release-count":2,"releases":[\#(release(releaseDeluxe, "Continuum (Deluxe)", "2021", [(rec1, "First Light"), (rec2, "Drift"), (mb(102), "Bonus")])),\#(release(releaseOriginal, "Continuum", "2019-03-15", [(rec1, "First Light"), (rec2, "Drift")]))]}"#
            }
            return MockTransport.Response(status: 200, body: Data(body.utf8))
        }
    }

    func makeModel() -> AppModel {
        AppModel(store: store, lidarrStore: MemoryLidarrStore(), tokenStore: MemoryTokenStore(), matchIndexDirectory: nil,
                 dataDirectory: nil, gateDefaultsSuite: gateSuite, transport: transport, probeTransport: transport,
                 engine: FakeEngine(), defaults: defaults, systemNowPlaying: false, notifications: false)
    }

    var musicBrainzRequests: [URLRequest] { transport.inner.requests.filter { $0.url?.host == "musicbrainz.org" } }

    static let album = NotYetAlbum(title: "Continuum", artist: "Aurora Field", mbid: rgAlbum, artistMBID: artistMBID,
                                   year: 2019, kind: "Album")

    static func request(_ state: RequestState, recording: ExternalRecording, plan rg: MBID?, target: MBID? = nil)
        -> MagpieRequest {
        var r = MagpieRequest(recording: recording, tier: .standard, createdAt: t0)
        r.state = state
        r.albumTarget = target
        r.plan = rg.map { Plan(recordingMBID: recording.recordingMBID ?? rec1, releaseGroupMBID: $0, artistMBID: artistMBID,
                               lidarrArtistId: nil, mode: .finds) }
        return r
    }

    /// Albums, EPs and Singles with the studio releases, everything else under More, newest first; from MusicBrainz
    /// once per session (memory only), with the app's user agent.
    @Test func outsideArtistSections() async throws {
        let app = makeModel()
        let page = OutsideArtistModel(app: app, artist: NotYetArtist(name: "Aurora Field", mbid: artistMBID))
        await page.load()
        #expect(page.phase == .loaded)
        #expect(page.sections.albums.map(\.title) == ["Continuum"])
        #expect(page.sections.eps.map(\.title) == ["Drift EP"])
        #expect(page.sections.more.map(\.title) == ["Live at Home"] && page.sections.more.first?.kind == "Live")
        #expect(page.album(page.sections.albums[0]) == Self.album)
        #expect(musicBrainzRequests.count == 1)
        #expect(musicBrainzRequests.first?.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("Magpie/") == true)
        await OutsideArtistModel(app: app, artist: NotYetArtist(name: "Aurora Field", mbid: artistMBID)).load()
        #expect(musicBrainzRequests.count == 1, "read once per session, kept in memory")
    }

    /// The album page lists the release Magpie picks: official, the earliest (not the later deluxe one).
    @Test func outsideAlbumTracklistIsThePickedRelease() async throws {
        let app = makeModel()
        let page = OutsideAlbumModel(app: app, album: Self.album, librarySong: { _ in nil })
        await page.load()
        #expect(page.phase == .loaded)
        #expect(page.release?.id == releaseOriginal)
        #expect(page.tracks.map(\.title) == ["First Light", "Drift"])
        #expect(page.tracks.allSatisfy { $0.artistMBID == artistMBID && $0.artist == "Aurora Field" })
        // Try this album: the first track stands for the album, aimed at its release group.
        let target = try #require(page.tryTarget)
        #expect(target.recording.recordingMBID == rec1 && target.albumGroup == rgAlbum && target.album == Self.album)
        #expect(page.row(0) == .tryIt && page.row(1) == .tryIt)
    }

    /// Offline: "You're offline", and nothing is asked of MusicBrainz.
    @Test func offlineShowsYoureOffline() async throws {
        let app = makeModel()
        app.updatePreferences { $0.downloads.offlineMode = .on }
        let artistPage = OutsideArtistModel(app: app, artist: NotYetArtist(name: "Aurora Field", mbid: artistMBID))
        await artistPage.load()
        let albumPage = OutsideAlbumModel(app: app, album: Self.album, librarySong: { _ in nil })
        await albumPage.load()
        #expect(artistPage.phase == .offline && albumPage.phase == .offline)
        #expect(musicBrainzRequests.isEmpty)
        #expect(AppModel.offlineCopy == "You're offline")
    }

    /// A per-track Try for a song on an album already on its way opens that request (R20): the track's row is the
    /// request, and the Try sheet opens on it; a song's own request comes first.
    @Test func perTrackTryDedupesAgainstALiveAlbumRequest() {
        let track = ExternalRecording(recordingMBID: rec2, artistMBID: artistMBID, title: "Drift", artist: "Aurora Field",
                                      source: .lidarr)
        let first = ExternalRecording(recordingMBID: rec1, artistMBID: artistMBID, title: "First Light", artist: "Aurora Field",
                                      source: .lidarr)
        // Try this album just started (not resolved yet: its target is the release group).
        let albumTry = Self.request(.resolving, recording: first, plan: nil, target: rgAlbum)
        #expect(OutsideAlbumModel.row(for: track, releaseGroup: rgAlbum, requests: [albumTry], readySongs: [:], landed: [:])
                == .request(albumTry.id))
        #expect(TrySheet.existingPhase(for: track, releaseGroup: rgAlbum, in: [albumTry]) == .waiting(albumTry.id))
        // Resolved to the album by another song.
        let songTry = Self.request(.searching, recording: first, plan: rgAlbum)
        #expect(OutsideAlbumModel.row(for: track, releaseGroup: rgAlbum, requests: [songTry], readySongs: [:], landed: [:])
                == .request(songTry.id))
        // Another album's request, or a stopped one: Try as usual.
        let other = Self.request(.searching, recording: first, plan: rgLive)
        let stopped = Self.request(.cancelled, recording: first, plan: rgAlbum)
        #expect(OutsideAlbumModel.row(for: track, releaseGroup: rgAlbum, requests: [other, stopped], readySongs: [:],
                                      landed: [:]) == .tryIt)
        #expect(TrySheet.existingPhase(for: track, releaseGroup: rgAlbum, in: [other, stopped]) == nil)
    }

    /// The album lands: the page asks the library again and its tracks turn into library songs in place.
    @Test func anItemThatLandsUpdatesInPlace() async throws {
        let app = makeModel()
        let landedSong = Song(id: "lib-1", title: "First Light", artist: "Aurora Field", album: "Continuum", duration: 60)
        let asked = Box()
        let page = OutsideAlbumModel(app: app, album: Self.album, librarySong: { recording in
            asked.count += 1
            return recording.recordingMBID == rec1 ? landedSong : nil
        })
        await page.load()
        #expect(asked.count == 0, "nothing Ready: the library isn't asked")
        var albumTry = Self.request(.downloading(progress: 0.5), recording: page.tracks[0], plan: rgAlbum, target: rgAlbum)
        app.requests = [albumTry]
        #expect(page.row(0) == .request(albumTry.id) && page.row(1) == .request(albumTry.id))
        #expect(page.albumRequest?.id == albumTry.id)
        albumTry.state = .ready
        app.requests = [albumTry]
        #expect(page.landingKey == [albumTry.id])
        await page.refreshLanded()
        #expect(page.row(0) == .library(landedSong), "the landed track plays from the library")
        #expect(page.row(1) == .request(albumTry.id), "a track the library doesn't list yet still opens the request")
    }
}

@MainActor private final class Box { var count = 0 }
