import Foundation
import ListenBrainzKit
import MagpieCore
import MatchIndex

/// Home "Made for you": the playlists ListenBrainz makes for the token's user (Daily Jams, Weekly Jams, Weekly
/// Exploration, ...), the newest of each kind, and a playlist's songs split by the match ladder into library songs
/// (playable) and songs not in the library (Try). Read-only. Every call is on `api.listenbrainz.org` with the token
/// (A9) within the client's 5 s limit; anything that fails or runs out of time leaves the section out, quietly.
public struct MadeForYou: Sendable {
    public struct Playlist: Hashable, Sendable, Identifiable {
        public var id: MBID
        /// "Daily Jams", "Weekly Exploration", ... (the playlist's own title for kinds Magpie doesn't know).
        public var title: String
        /// The day it was made.
        public var date: Date?

        public init(id: MBID, title: String, date: Date? = nil) { self.id = id; self.title = title; self.date = date }
    }

    public enum Track: Hashable, Sendable {
        /// Already in the library (≥ the ladder's accept threshold, or an unambiguous name match).
        case library(songId: String, ExternalRecording)
        case notYet(ExternalRecording)
    }

    /// Most playlists on the shelf.
    public static let shelfLimit = 6

    /// Friendly names for the kinds ListenBrainz makes (`source_patch`).
    static let kindTitles = ["daily-jams": "Daily Jams", "weekly-jams": "Weekly Jams",
                             "weekly-exploration": "Weekly Exploration"]

    private let client: ListenBrainzClient

    public init(client: ListenBrainzClient) { self.client = client }

    /// The shelf for the token's user, newest first. Empty without a valid token or when anything fails.
    public func playlists() async -> [Playlist] {
        guard let user = try? await client.tokenUser(),
              let refs = try? await client.createdForPlaylists(user: user) else { return [] }
        return Self.shelf(refs)
    }

    /// The playlist's songs, resolved against `index`. Nil when they can't be read.
    public func tracks(_ id: MBID, index: MatchIndex) async -> [Track]? {
        guard let recordings = try? await client.playlistTracks(id) else { return nil }
        return Self.resolve(recordings, index: index)
    }

    /// The newest playlist of each kind (playlists of no known kind each stand alone), each id once, newest first, at most
    /// `shelfLimit`.
    static func shelf(_ refs: [LBPlaylistRef]) -> [Playlist] {
        // ISO 8601 dates in one offset sort as text; undated ones go last, in the order given.
        let ordered = refs.enumerated().sorted { a, b in
            switch (a.element.date, b.element.date) {
            case let (x?, y?) where x != y: x > y
            case (.some, nil): true
            case (nil, .some): false
            default: a.offset < b.offset
            }
        }.map(\.element)
        var seenKinds = Set<String>(), seenIds = Set<MBID>()
        var shelf: [Playlist] = []
        for ref in ordered where shelf.count < shelfLimit {
            guard !seenIds.contains(ref.id) else { continue }   // listed twice: once (Home keys cards by id)
            if let kind = ref.sourcePatch, !seenKinds.insert(kind).inserted { continue }
            seenIds.insert(ref.id)
            shelf.append(Playlist(id: ref.id, title: ref.sourcePatch.flatMap { kindTitles[$0] } ?? ref.title,
                                  date: ref.date.flatMap(Self.day)))
        }
        return shelf
    }

    public static func resolve(_ recordings: [ExternalRecording], index: MatchIndex) -> [Track] {
        recordings.map { r in index.librarySong(for: r).map { .library(songId: $0, r) } ?? .notYet(r) }
    }

    /// The `yyyy-MM-dd` part of an ISO 8601 date.
    private static func day(_ iso: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        return f.date(from: String(iso.prefix(10)))
    }
}
