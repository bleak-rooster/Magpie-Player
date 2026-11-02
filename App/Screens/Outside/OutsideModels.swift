import Foundation
import ListenBrainzKit
import MagpieCore
import Observation
import Requests
import Search

/// What an outside page is showing.
enum OutsidePhase: Equatable {
    case loading
    /// "You're offline": nothing is asked of MusicBrainz.
    case offline
    case failed
    case loaded
}

/// R19: an artist that's not in the library, styled like the library Artist page: the picture (R15, memory only),
/// the name, the Lidarr status line (W3: an owner's artist is never changed), and the albums from MusicBrainz.
/// Popular songs are left out: the app has no top-recordings source (spec call).
@MainActor @Observable final class OutsideArtistModel {
    private(set) var phase = OutsidePhase.loading
    private(set) var sections = OutsideArtistSections()
    let artist: NotYetArtist
    /// "Add to your library" (R18's Add sheet or Add with my defaults, through the gate) and the W3 status line.
    let lidarrLine: ArtistLidarrModel
    @ObservationIgnored private let app: AppModel

    init(app: AppModel, artist: NotYetArtist) {
        self.app = app
        self.artist = artist
        lidarrLine = ArtistLidarrModel(model: app, name: artist.name, mbid: artist.mbid)
    }

    /// The page's one task (review I2): builds the model when there's none, shows it, then loads it, so the page
    /// loads whatever order SwiftUI runs its tasks in.
    static func open(_ existing: OutsideArtistModel?, app: AppModel, artist: NotYetArtist,
                     show: (OutsideArtistModel) -> Void) async -> OutsideArtistModel {
        let model = existing ?? OutsideArtistModel(app: app, artist: artist)
        show(model)
        await model.load()
        return model
    }

    /// Try this album on this row can work (see `OutsideAlbumModel.canTryAlbum`).
    func canTryAlbum(_ item: OutsideArtistSections.Item) -> Bool {
        OutsideAlbumModel.canTryAlbum(kind: item.kind, artist: lidarrLine.state)
    }

    func load() async {
        guard !app.isOffline else { phase = .offline; return }
        if phase != .loaded { phase = .loading }
        if let mbid = artist.mbid {
            do {
                sections = OutsideArtistSections.make(try await app.outsideCatalog.releaseGroups(artist: mbid))
                phase = .loaded
            } catch {
                phase = app.isOffline ? .offline : .failed
            }
        } else {
            phase = .failed
        }
        await lidarrLine.refresh()
    }

    /// A row's album, for its page and its Try.
    func album(_ item: OutsideArtistSections.Item) -> NotYetAlbum {
        NotYetAlbum(title: item.title, artist: artist.name, mbid: item.id, artistMBID: artist.mbid, year: item.year,
                    kind: item.kind)
    }
}

/// What one track of an outside album is right now.
enum OutsideTrackRow: Equatable {
    /// Try (the single-song Try).
    case tryIt
    /// On its way (the song's own request, or its album's): opens the request, never a second Try (R17, R20).
    case request(RequestID)
    /// In the library now: played like any library song (R17 live rows).
    case library(Song)
}

/// R19: an album that's not in the library: the cover (R15), the tracklist of the release Magpie picks
/// (`OutsideReleasePick`), Try this album, Add <artist> to your library, and a Try per track.
@MainActor @Observable final class OutsideAlbumModel {
    private(set) var phase = OutsidePhase.loading
    private(set) var release: MBReleaseDetail?
    private(set) var tracks: [ExternalRecording] = []
    /// Tracks the library has now, by recording: the page updates in place when the album lands.
    private(set) var landed: [MBID: Song] = [:]
    let album: NotYetAlbum
    let lidarrLine: ArtistLidarrModel
    @ObservationIgnored private let app: AppModel
    @ObservationIgnored private let librarySong: @MainActor (ExternalRecording) async -> Song?

    init(app: AppModel, album: NotYetAlbum,
         librarySong: (@MainActor (ExternalRecording) async -> Song?)? = nil) {
        self.app = app
        self.album = album
        self.librarySong = librarySong ?? { [weak app] in await app?.librarySong(for: $0) }
        lidarrLine = ArtistLidarrModel(model: app, name: album.artist, mbid: album.artistMBID)
    }

    /// The page's one task (review I2), as for the artist page.
    static func open(_ existing: OutsideAlbumModel?, app: AppModel, album: NotYetAlbum,
                     show: (OutsideAlbumModel) -> Void) async -> OutsideAlbumModel {
        let model = existing ?? OutsideAlbumModel(app: app, album: album)
        show(model)
        await model.load()
        return model
    }

    /// Whether Try this album can work: a studio Album, EP or Single (or an unknown kind) for any artist; a release
    /// with a secondary type (Live, Compilation…) only for an artist known to be in Lidarr. A new artist's add can
    /// only monitor what the Finds metadata profile lists (official studio releases), so it would always fail.
    nonisolated static func canTryAlbum(kind: String?, artist: ArtistLidarrState?) -> Bool {
        if kind == nil || ["album", "ep", "single"].contains(kind!.lowercased()) { return true }
        switch artist {
        case .monitored?, .notMonitored?, .find?: return true   // Y5: one of Magpie's finds is in Lidarr
        case .notInLidarr?, .unmatched?, nil: return false
        }
    }

    var canTryAlbum: Bool { tryTarget != nil && Self.canTryAlbum(kind: album.kind, artist: lidarrLine.state) }

    func load() async {
        guard !app.isOffline else { phase = .offline; return }
        if phase != .loaded { phase = .loading }
        if let rg = album.mbid {
            do {
                release = try await app.outsideCatalog.release(releaseGroup: rg)
                tracks = release.map { OutsideReleasePick.recordings($0, artist: album.artist, artistMBID: album.artistMBID) } ?? []
                phase = .loaded
            } catch {
                phase = app.isOffline ? .offline : .failed
            }
        } else {
            phase = .failed
        }
        await lidarrLine.refresh()
        await refreshLanded()
    }

    /// The live request bringing this album in (Try this album, or a song of it resolved to this release group).
    var albumRequest: MagpieRequest? { RequestLinks.request(releaseGroup: album.mbid, in: app.requests) }

    func row(_ index: Int) -> OutsideTrackRow {
        guard tracks.indices.contains(index) else { return .tryIt }
        return Self.row(for: tracks[index], releaseGroup: album.mbid, requests: app.requests, readySongs: app.readySongs,
                        landed: landed)
    }

    /// In the library first; then the song's own live request; then its album's (R20: deduped by release group).
    nonisolated static func row(for track: ExternalRecording, releaseGroup: MBID?, requests: [MagpieRequest],
                                readySongs: [RequestID: Song], landed: [MBID: Song]) -> OutsideTrackRow {
        if let id = track.recordingMBID, let song = landed[id] { return .library(song) }
        switch RequestLinks.songRow(for: track, in: requests, readySongs: readySongs) {
        case .library(let song, _): return .library(song)
        case .request(let id): return .request(id)
        case .tryIt: break
        }
        if let live = RequestLinks.request(releaseGroup: releaseGroup, in: requests) { return .request(live.id) }
        return .tryIt
    }

    /// What changes when something lands: Ready requests for this album or its songs (the page asks the library again).
    var landingKey: [RequestID] {
        app.requests.filter { r in
            r.state == .ready && ((r.plan?.releaseGroupMBID ?? r.albumTarget) == album.mbid
                                  || tracks.contains { RequestRunner.sameSong($0, r.recording) })
        }.map(\.id)
    }

    /// Asks the library for each track not shown as a library song yet, when something for this album is Ready.
    func refreshLanded() async {
        guard !landingKey.isEmpty else { return }
        for track in tracks {
            guard let id = track.recordingMBID, landed[id] == nil, let song = await librarySong(track) else { continue }
            landed[id] = song
        }
    }

    /// The first track stands for the album in its request (it lands when the album does).
    var tryTarget: TryTarget? {
        guard let first = tracks.first, let rg = album.mbid else { return nil }
        return TryTarget(recording: first, album: album, albumGroup: rg)
    }
}
