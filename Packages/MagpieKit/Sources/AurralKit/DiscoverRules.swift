import Foundation
import MagpieCore

/// A Navidrome playlist that is one of Aurral's flows.
public struct DiscoverPlaylist: Sendable, Equatable, Hashable {
    public var flow: AurralFlow
    public var playlist: Playlist
    public init(flow: AurralFlow, playlist: Playlist) { self.flow = flow; self.playlist = playlist }
}

/// One song of a Discover playlist as Magpie shows and plays it: the main library's copy in place of Aurral's when
/// the library has the same recording ("In your library"), else the flow song itself.
public struct DiscoverEntry: Sendable, Equatable, Hashable {
    /// What shows and plays.
    public var song: Song
    /// The flow song as Navidrome lists it in the playlist.
    public var original: Song
    public var inYourLibrary: Bool { song.id != original.id }

    public init(song: Song, original: Song) { self.song = song; self.original = original }
}

/// An artist of a Discover playlist ("Artists in this playlist").
public struct DiscoverArtist: Sendable, Equatable, Hashable, Identifiable {
    public var name: String
    public var mbid: MBID?
    public var id: String { mbid?.rawValue ?? "name:" + DiscoverRules.normalised(name) }
    public init(name: String, mbid: MBID?) { self.name = name; self.mbid = mbid }
}

/// Round 12 Y6 (plan item 7): Discover's rules, pure so they're tested on their own.
///
/// No writes to Aurral's data: the swap happens only in what Magpie shows and plays.
public enum DiscoverRules {
    /// Case, diacritics, surrounding and repeated spaces folded.
    public static func normalised(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    // MARK: - Flows ↔ playlists

    /// The Navidrome playlists that are Aurral's flows: named exactly as a flow (folded), or "<owner> - <flow>" (Aurral's
    /// optional user-name prefix). In the playlists' order; a blank name matches nothing.
    public static func flowPlaylists(flows: [AurralFlow], playlists: [Playlist]) -> [DiscoverPlaylist] {
        var byName: [String: AurralFlow] = [:]
        for flow in flows {
            let name = normalised(flow.name)
            guard !name.isEmpty else { continue }
            if byName[name] == nil { byName[name] = flow }
            if let owner = flow.ownerUsername.map(normalised), !owner.isEmpty, byName[owner + " - " + name] == nil {
                byName[owner + " - " + name] = flow
            }
        }
        return playlists.compactMap { playlist in
            let name = normalised(playlist.name)
            guard !name.isEmpty, let flow = byName[name] else { return nil }
            return DiscoverPlaylist(flow: flow, playlist: playlist)
        }
    }

    /// Fix I1: of the playlists named after flows, the ones whose songs are the flow's: more than half of the entries are
    /// the flow's songs (by Aurral's jobs for that flow: recording id, else artist + title with the duration within 3 s
    /// when both are known) or songs known to be in Aurral's library. An empty playlist never counts. Of several for one
    /// flow, only the best (the larger share, then more songs, then the lower id). `entries` by playlist id.
    public static func confirmedFlowPlaylists(_ candidates: [DiscoverPlaylist], entries: [String: [Song]],
                                              jobs: [AurralJob], aurralSongIds: Set<String>) -> [DiscoverPlaylist] {
        var best: [String: (candidate: DiscoverPlaylist, share: Double, matched: Int)] = [:]
        for candidate in candidates {
            let songs = entries[candidate.playlist.id] ?? []
            guard !songs.isEmpty else { continue }
            let flowJobs = jobs.filter { $0.flowId == candidate.flow.id }
            let matched = songs.filter { aurralSongIds.contains($0.id) || isFlowSong($0, jobs: flowJobs) }.count
            guard matched * 2 > songs.count else { continue }
            let share = Double(matched) / Double(songs.count)
            if let current = best[candidate.flow.id] {
                let better = share != current.share ? share > current.share
                    : matched != current.matched ? matched > current.matched
                    : candidate.playlist.id < current.candidate.playlist.id
                guard better else { continue }
            }
            best[candidate.flow.id] = (candidate, share, matched)
        }
        let kept = Set(best.values.map(\.candidate.playlist.id))
        return candidates.filter { kept.contains($0.playlist.id) }
    }

    /// The song is one of these jobs': same recording id, else same artist and title (folded) with the durations within
    /// 3 s when both are known.
    static func isFlowSong(_ song: Song, jobs: [AurralJob]) -> Bool {
        jobs.contains { job in
            if let recording = song.recordingMBID, let track = job.trackMBID { return recording == track }
            return sameSong(song, job)
        }
    }

    private static func sameSong(_ song: Song, _ job: AurralJob) -> Bool {
        guard normalised(job.artistName) == normalised(song.artist), normalised(job.trackName) == normalised(song.title)
        else { return false }
        if let duration = job.duration, duration > 0, song.duration > 0 {
            return abs(duration - song.duration) <= durationTolerance
        }
        return true
    }

    /// Aurral's job's recording id for a flow song without one: the job of the same artist and title in the flow (any
    /// flow when nil), with the duration within 3 s when both are known (fix M3).
    public static func jobRecording(for song: Song, jobs: [AurralJob], flowId: String?) -> MBID? {
        jobs.first { (flowId == nil || $0.flowId == flowId) && $0.trackMBID != nil && sameSong(song, $0) }?.trackMBID
    }

    // MARK: - The main library's copy

    /// Most a duration may differ by for a match without a MusicBrainz id.
    public static let durationTolerance: TimeInterval = 3

    /// The main library's copy of `entry`, if there is one:
    /// 1. by MusicBrainz recording id (`recording`: the entry's own, else Aurral's job's), the first of `mbidMatches`
    ///    in the listed libraries;
    /// 2. else by artist + title + duration within 3 s: exactly one of `textMatches`, never with a duration unknown
    ///    on either side (never by name alone).
    /// Never the entry itself or any id in `excluding` (every Discover copy). `libraries`: the libraries the owner lists
    /// (nil: any), `notLibraries`: Discover's and the Finds library, never a copy's home.
    public static func mainCopy(for entry: Song, recording: MBID?, mbidMatches: [Song], textMatches: [Song],
                                excluding: Set<String>, libraries: Set<Int>? = nil,
                                notLibraries: Set<Int> = []) -> Song? {
        func eligible(_ song: Song) -> Bool {
            guard song.id != entry.id, !excluding.contains(song.id) else { return false }
            // A row without its library (search3's) comes from a search already scoped to the listed libraries.
            guard let library = song.libraryId else { return true }
            return !notLibraries.contains(library) && (libraries?.contains(library) ?? true)
        }
        if let recording {
            let byId = mbidMatches.filter { $0.recordingMBID == recording && eligible($0) }.sorted { $0.id < $1.id }
            if let first = byId.first { return first }
        }
        guard entry.duration > 0 else { return nil }
        let artist = normalised(entry.artist), title = normalised(entry.title)
        guard !artist.isEmpty, !title.isEmpty else { return nil }
        let byText = textMatches.filter { song in
            eligible(song) && song.duration > 0 && abs(song.duration - entry.duration) <= durationTolerance
                && normalised(song.artist) == artist && normalised(song.title) == title
        }
        var seen = Set<String>()
        let unique = byText.filter { seen.insert($0.id).inserted }
        return unique.count == 1 ? unique[0] : nil
    }

    /// The playlist's songs with each library copy in its entry's place (keyed by the entry's id); every other entry
    /// as it is.
    public static func swapped(_ songs: [Song], copies: [String: Song]) -> [DiscoverEntry] {
        songs.map { DiscoverEntry(song: copies[$0.id] ?? $0, original: $0) }
    }

    // MARK: - Aurral's library

    /// The Navidrome library (or libraries) holding Aurral's flow files: found from Aurral's job paths, never from a
    /// name. A flow song whose job's file is Aurral's own (in its `_flows` folder) is matched by recording id to the
    /// playlist entry; the entry's row (`rows[entry.id]`, Navidrome's lookup by that recording id) names its library.
    /// A library the owner lists is never Discover's (a reused Lidarr file lives there).
    /// Round 14 (D79 amendment): Aurral 2.13 no longer names its files (`toPublicJob` drops `finalPath`). When Aurral
    /// listed jobs but none carries a path, the library is the one holding the Discover playlists' own songs (each
    /// entry's own row), with the same exclusions; never learnt from Aurral's `libraryOwned`.
    public static func discoverLibraries(entries: [Song], rows: [String: [Song]], jobs: [AurralJob],
                                         listed: Set<Int>) -> Set<Int> {
        let pathsHidden = !jobs.isEmpty && jobs.allSatisfy { $0.finalPath == nil }
        let ownFiles = Set(jobs.filter(\.isAurralsOwnFile).compactMap(\.trackMBID))
        var found = Set<Int>()
        for entry in entries {
            if !pathsHidden {
                guard let recording = entry.recordingMBID, ownFiles.contains(recording) else { continue }
            }
            guard let row = rows[entry.id]?.first(where: { $0.id == entry.id }), let library = row.libraryId,
                  !listed.contains(library) else { continue }
            found.insert(library)
        }
        return found
    }

    // MARK: - Artists

    /// The artist's MusicBrainz id for a playlist song, from Aurral's job for it: by recording id, else by the
    /// artist's name within the flow.
    public static func artistMBID(for entry: Song, jobs: [AurralJob], flowId: String?) -> MBID? {
        let flowJobs = jobs.filter { flowId == nil || $0.flowId == flowId }
        if let recording = entry.recordingMBID,
           let mbid = flowJobs.first(where: { $0.trackMBID == recording })?.artistMBID { return mbid }
        let name = normalised(entry.artist)
        return flowJobs.first { normalised($0.artistName) == name && $0.artistMBID != nil }?.artistMBID
    }

    /// The playlist's artists, in order of first appearance, once each (by MusicBrainz id, else by name).
    public static func artists(entries: [Song], jobs: [AurralJob], flowId: String?) -> [DiscoverArtist] {
        var seen = Set<String>()
        var result: [DiscoverArtist] = []
        for entry in entries where !normalised(entry.artist).isEmpty {
            let artist = DiscoverArtist(name: entry.artist, mbid: artistMBID(for: entry, jobs: jobs, flowId: flowId))
            let nameKey = "name:" + normalised(entry.artist)
            guard !seen.contains(artist.id), !seen.contains(nameKey) else { continue }
            seen.insert(artist.id)
            seen.insert(nameKey)
            result.append(artist)
        }
        return result
    }
}
