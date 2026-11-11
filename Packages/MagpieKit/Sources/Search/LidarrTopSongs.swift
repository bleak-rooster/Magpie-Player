import AurralKit
import Foundation
import LidarrKit
import MagpieCore
import MatchIndex

/// Round 26 K1 (owner, 2026-11-10): the Top songs of an artist Lidarr has (`ArtistLidarrState.topSongsLidarrArtistId`,
/// D257): "Magpie should check Aurral, then Listenbrainz, then Navidrome for top songs … If it is unable to find a match,
/// then it should move that and try fill the position with the next song underneath it. A total of 5 songs should be
/// included and can be mixed between aurral, listenbrainz and navidrome."
///
/// The merge is pure: the app reads the three sources (and Lidarr's albums and tracks) and says how to resolve each
/// candidate to a library song (`link`, then `getSong`); this walks them in the fixed order and places at most five
/// (D258), and says whether the list is complete enough to replace a saved one (D262).
public enum LidarrTopSongs {
    /// "A total of 5 songs".
    public static let limit = 5
    /// The fixed order (D258): the Settings picker doesn't apply to an artist in Lidarr (D266).
    public static let order: [TopSongsProvider] = [.aurral, .listenBrainz, .library]

    /// How deep each source is read: Aurral's list whole (at most 6: its server asks Deezer for 6, plan §2.3), the first
    /// 25 of ListenBrainz's and Navidrome's (the same single call; enough to fill five slots).
    public static func readDepth(_ provider: TopSongsProvider) -> Int {
        provider == .aurral ? 6 : 25
    }

    /// One source's answer. `unavailable`: not set up for this artist (no Aurral, no token, no MBID); never asked, and it
    /// doesn't make the list incomplete. `failed`: asked and didn't answer (an error or the deadline). An empty answer is
    /// an answer.
    public enum Answer<Candidate> {
        case unavailable
        case failed
        case answered([Candidate])
    }

    /// The three sources, by name, so the order can't be got wrong.
    public struct Sources<Candidate> {
        public var aurral: Answer<Candidate>
        public var listenBrainz: Answer<Candidate>
        public var library: Answer<Candidate>

        public init(aurral: Answer<Candidate>, listenBrainz: Answer<Candidate>, library: Answer<Candidate>) {
            self.aurral = aurral; self.listenBrainz = listenBrainz; self.library = library
        }

        public subscript(provider: TopSongsProvider) -> Answer<Candidate> {
            switch provider {
            case .aurral: aurral
            case .listenBrainz: listenBrainz
            case .library: library
            }
        }
    }

    /// What a candidate is in the library. `lidarrUnread`: no direct match, and Lidarr's albums and tracks couldn't be
    /// read, so the album step couldn't run: skipped, and the list is incomplete.
    public enum Resolution: Sendable, Equatable {
        case song(Song)
        case notInLibrary
        case lidarrUnread
    }

    public struct Row: Sendable, Hashable {
        public var song: Song
        /// Where it came from (kept for tests and the saved list; never shown, plan §3 h).
        public var source: TopSongsProvider

        public init(song: Song, source: TopSongsProvider) { self.song = song; self.source = source }
    }

    public struct Result: Sendable, Equatable {
        public var rows: [Row]
        /// False when a source the walk reached before the list was full `failed` (fix round 1, C3), a resolve said Lidarr
        /// was unread, or the walk was cancelled: such a list never
        /// replaces a saved one (D262, D264).
        public var complete: Bool

        public init(rows: [Row], complete: Bool) { self.rows = rows; self.complete = complete }
    }

    /// Walks Aurral's list, then ListenBrainz's, then Navidrome's, each top-down to its `readDepth`, and places each
    /// candidate `resolve` finds in the library, until `limit` (at most 5) are placed. A song is skipped when its id is
    /// placed already, when a song with the same strict title (`TopSongIdentity`) is (two copies of one song), or when it
    /// lives in one of Discover's libraries. Nothing is resolved once the list is full.
    public static func merge<Candidate: Sendable>(
        sources: Sources<Candidate>, discoverLibraries: Set<Int> = [], limit: Int = limit,
        isolation: isolated (any Actor)? = #isolation,
        resolve: (TopSongsProvider, Candidate) async -> Resolution
    ) async -> Result {
        let wanted = min(max(limit, 0), Self.limit)
        var rows: [Row] = []
        var ids = Set<String>(), titles = Set<String>()
        var complete = true
        for provider in order {
            let candidates: [Candidate]
            switch sources[provider] {
            case .unavailable: continue
            // Fix round 1 (controller ruling C3): a failure counts only when the walk reached it with a slot still open; a
            // source after the five were filled couldn't have changed them.
            case .failed: if rows.count < wanted { complete = false }; continue
            case .answered(let list): candidates = Array(list.prefix(readDepth(provider)))
            }
            for candidate in candidates where rows.count < wanted {
                guard !Task.isCancelled else { return Result(rows: rows, complete: false) }
                switch await resolve(provider, candidate) {
                case .notInLibrary: continue
                case .lidarrUnread: complete = false
                case .song(let song):
                    let title = TopSongIdentity.titleKey(song.title)
                    guard !ids.contains(song.id), title.isEmpty || !titles.contains(title),
                          song.libraryId.map(discoverLibraries.contains) != true else { continue }
                    ids.insert(song.id)
                    if !title.isEmpty { titles.insert(title) }
                    rows.append(Row(song: song, source: provider))
                }
            }
        }
        if Task.isCancelled { complete = false }   // fix round 1 (M2): cancelled inside the last resolve
        return Result(rows: rows, complete: complete)
    }

    // MARK: - Resolving an Aurral or ListenBrainz song

    /// Lidarr's albums and tracks of the artist (read only when Aurral or ListenBrainz is available), or a failed read.
    public enum LidarrReads: Sendable {
        case read(albums: [LidarrAlbum], tracks: [LidarrTrack])
        case failed
    }

    /// What an Aurral or ListenBrainz song is in the library.
    public enum Link: Sendable, Equatable {
        /// The library song's id from the direct ladder (D259): no re-check needed beyond being that song.
        case song(id: String)
        /// Fix round 1 (I2): the album step's track linked through the index (D260). The index keeps `Normalize.name`d
        /// titles, which fold "(Reprise)", "(Interlude)", "(Intro)", "(Outro)", "(Extended)", "(Dub)"… to the plain
        /// title, so the fetched song must pass `confirms` (the strict title on its full title) before it is shown.
        case albumSong(id: String, track: LidarrTrack, album: LidarrAlbum)
        /// The album step found a track with a file the index can't link (a song too new for it). The app may search for
        /// it and must hold what it finds to `AlbumTrackMatch.links` before showing it.
        case track(LidarrTrack, album: LidarrAlbum)
        /// Not in the library, as far as can be proven: skipped.
        case none
        /// No direct match, and Lidarr's reads failed: skipped, and the list is incomplete.
        case lidarrUnread
    }

    /// D259, then D260: the match index's ladder (`MatchIndex.librarySong`, as for every outside song), else the album step
    /// through Lidarr's tracklist (`AlbumTrackMatch.find`) and its link to the library (`AlbumTrackMatch.librarySongId`).
    /// `avoiding` names song ids the caller knows are Discover copies (fix round 1, M5; the index doesn't keep a song's
    /// library): a recording's copy outside them is taken first, so a Discover copy never hides the main one.
    public static func link(_ recording: ExternalRecording, artistName: String, artistMBID: MBID?, index: MatchIndex,
                            lidarr: LidarrReads, avoiding: (String) -> Bool = { _ in false }) -> Link {
        if let rec = recording.recordingMBID, let id = index.songId(recording: rec, avoiding: avoiding) {
            return .song(id: id)   // the ladder's tier 1, with the preference
        }
        if let id = index.librarySong(for: recording) { return .song(id: id) }
        guard case .read(let albums, let tracks) = lidarr else { return .lidarrUnread }
        guard let track = AlbumTrackMatch.find(title: recording.title, duration: recording.duration,
                                               recording: recording.recordingMBID, albums: albums, tracks: tracks),
              let album = AlbumTrackMatch.album(of: track, in: albums) else { return .none }
        if let id = AlbumTrackMatch.librarySongId(track: track, album: album, artistName: artistName,
                                                  artistMBID: artistMBID, index: index, avoiding: avoiding) {
            return .albumSong(id: id, track: track, album: album)
        }
        return .track(track, album: album)
    }

    /// Fix round 1 (I2): whether a fetched library song (`getSong`, or a search hit for `.track`) may be shown for a link.
    /// `.song`: it is that song. `.albumSong`: it is that song and passes `AlbumTrackMatch.links` on its full title.
    /// `.track`: it passes `AlbumTrackMatch.links`. Anything else: no. K2 calls this before its resolve answers `.song`.
    public static func confirms(_ song: Song, _ link: Link, artistName: String, artistMBID: MBID?) -> Bool {
        switch link {
        case .song(let id): song.id == id
        case .albumSong(let id, let track, let album):
            song.id == id && AlbumTrackMatch.links(song, to: track, album: album, artistName: artistName, artistMBID: artistMBID)
        case .track(let track, let album):
            AlbumTrackMatch.links(song, to: track, album: album, artistName: artistName, artistMBID: artistMBID)
        case .none, .lidarrUnread: false
        }
    }

    /// An Aurral top song as the ladder reads it (D259): its title and length, with the page's artist name and MBID (the
    /// server's credit may add featured artists; it was asked for this artist's songs). A length that isn't one is nil.
    public static func recording(aurral song: AurralSong, artistName: String, artistMBID: MBID?) -> ExternalRecording {
        // `.lidarr`: `ExternalSource` has no Aurral case, and `match`/`librarySong` never read the source.
        ExternalRecording(artistMBID: artistMBID, title: song.trackName, artist: artistName,
                          duration: AlbumTrackMatch.known(song.duration), source: .lidarr)
    }
}

extension LidarrTopSongs.Answer: Sendable where Candidate: Sendable {}
extension LidarrTopSongs.Sources: Sendable where Candidate: Sendable {}
