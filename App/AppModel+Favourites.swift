import Foundation
import MagpieCore
import NavidromeKit
import Observation
import os

/// Something the user can favourite (Subsonic `star`): a song (`id`), an album (`albumId`) or an artist (`artistId`).
/// Navidrome 0.64.2 stars all three (verified on the dev stack, round 11 R7).
enum FavouriteTarget: Hashable {
    case song(String), album(String), artist(String)
}

/// The library's edits that screens share (round 11 R7, R8): what is favourited, the Add to playlist sheet being
/// asked for, when the playlists last changed, and the short notice that confirms or explains an edit. One object, so
/// `AppModel` holds a single property for it.
@MainActor @Observable final class LibraryEdits {
    /// The user's stars this session: optimistic, so they win over what the server last said.
    var overrides: [FavouriteTarget: Bool] = [:]
    /// What the server last said, noted as pages load (an album or artist page, Favourites).
    var known: [FavouriteTarget: Bool] = [:]
    /// The latest change per target: a failure rolls back only if no newer change came since.
    @ObservationIgnored var changeTokens: [FavouriteTarget: Int] = [:]
    @ObservationIgnored var nextToken = 0

    /// Add to playlist asked for from a menu (`AddToPlaylistPresenter` shows the sheet).
    var addToPlaylist: AddToPlaylistRequest?
    /// Bumped after every playlist change, so open lists read again.
    var playlistsRevision = 0
    /// A short message: an edit that worked ("Added to Road trip") or one that didn't.
    var notice: LibraryNotice?

    func notify(_ text: String, symbol: String) {
        nextToken += 1
        notice = LibraryNotice(id: nextToken, text: text, symbol: symbol)
    }

    /// Sign-out: nothing of the old account stays.
    func reset() {
        overrides = [:]
        known = [:]
        changeTokens = [:]
        addToPlaylist = nil
        notice = nil
        playlistsRevision += 1
    }
}

/// A notice shown briefly over the screen (text and symbol, D3).
struct LibraryNotice: Equatable, Identifiable {
    let id: Int
    let text: String
    let symbol: String
}

/// The songs a menu asked to add to a playlist.
struct AddToPlaylistRequest: Identifiable, Equatable {
    let id = UUID()
    let songIds: [String]
}

enum FavouriteCopy {
    static let addFailed = "Couldn't add that to your favourites. Try again in a moment."
    static let removeFailed = "Couldn't remove that from your favourites. Try again in a moment."
    static func label(_ on: Bool) -> String { on ? "Unfavourite" : "Favourite" }
}

/// Favourites (round 11 R7): optimistic stars for songs, albums and artists, rolled back with a notice when the server
/// says no. Offline nothing is queued: the notice says "You're offline" and nothing changes (the simpler of the spec's
/// two options).
extension AppModel {
    /// Whether `target` is favourited: the user's change this session, else what the server last said (for a song,
    /// the copy in the queue when no page has said).
    func isFavourite(_ target: FavouriteTarget) -> Bool {
        if let mine = libraryEdits.overrides[target] { return mine }
        if let said = libraryEdits.known[target] { return said }
        if case .song(let id) = target {
            let queue = player.queue
            return (queue.main + queue.upNext).first { $0.song.id == id }?.song.starred ?? false
        }
        return false
    }

    /// `isFavourite` for an item read with its own `starred` (a list row): that, unless the session knows better.
    func isFavourite(_ target: FavouriteTarget, given starred: Bool) -> Bool {
        libraryEdits.overrides[target] ?? libraryEdits.known[target] ?? starred
    }

    /// Favourites or unfavourites `target` at once, then tells the server; a refusal rolls back with a notice.
    func setFavourite(_ target: FavouriteTarget, _ on: Bool) async {
        await setFavourite(target, on, was: isFavourite(target))
    }

    /// What the server said about an album, artist or song, as a page loaded. A change the user made this session
    /// still wins.
    func noteFavourite(_ target: FavouriteTarget, _ starred: Bool) {
        if libraryEdits.known[target] != starred { libraryEdits.known[target] = starred }
    }

    /// Notes every item of a Favourites read as favourited.
    func noteFavourites(_ starred: Starred) {
        for song in starred.songs { noteFavourite(.song(song.id), true) }
        for album in starred.albums { noteFavourite(.album(album.id), true) }
        for artist in starred.artists { noteFavourite(.artist(artist.id), true) }
    }

    func isStarred(_ song: Song) -> Bool { libraryEdits.overrides[.song(song.id)] ?? song.starred }

    /// Now Playing's star: optimistic, reverts (with a notice) if the server says no.
    func toggleStar(_ song: Song) async {
        let was = isStarred(song)
        await setFavourite(.song(song.id), !was, was: was)
    }

    private func setFavourite(_ target: FavouriteTarget, _ on: Bool, was: Bool) async {
        if isOffline {
            libraryEdits.notify(Self.offlineCopy, symbol: "wifi.slash")
            return
        }
        let edits = libraryEdits
        edits.nextToken += 1
        let token = edits.nextToken
        edits.changeTokens[target] = token
        edits.overrides[target] = on
        do {
            try await request { client in
                switch target {
                case .song(let id): on ? try await client.star(id: id) : try await client.unstar(id: id)
                case .album(let id): on ? try await client.star(albumId: id) : try await client.unstar(albumId: id)
                case .artist(let id): on ? try await client.star(artistId: id) : try await client.unstar(artistId: id)
                }
            }
            if case .song = target { favouriteStarChanged() }
        } catch {
            Log.logger("session").error("star failed: \(Log.category(of: error), privacy: .public)")
            guard edits.changeTokens[target] == token else { return }   // a newer change owns the state now
            edits.overrides[target] = was
            edits.notify(on ? FavouriteCopy.addFailed : FavouriteCopy.removeFailed, symbol: "exclamationmark.triangle")
        }
    }
}
