import DesignSystem
import MagpieCore
import Playback
import SwiftUI

/// A song's long-press items from round 11 (R7, R8): Add to playlist… and Favourite / Unfavourite. Offline, and for a
/// song the phone grouped itself, they step aside (the server can't be asked).
struct SongLibraryMenuItems: View {
    @Environment(AppModel.self) private var model
    let song: Song

    var body: some View {
        if !model.isOffline, !OfflineCatalog.isLocalId(song.id) {
            Button(PlaylistCopy.addToPlaylist, systemImage: "text.badge.plus") { model.askToAddToPlaylist([song.id]) }
            FavouriteMenuItem(target: .song(song.id), rowStarred: song.starred)
        }
    }
}

/// Favourite / Unfavourite for a row's menu. `rowStarred` is what the row's own item says; the session's changes
/// win over it, and a refused change rolls back to it (review fix I3).
struct FavouriteMenuItem: View {
    @Environment(AppModel.self) private var model
    let target: FavouriteTarget
    let rowStarred: Bool

    var body: some View {
        let starred = model.isFavourite(target, given: rowStarred)
        Button(FavouriteCopy.label(starred), systemImage: starred ? "star.slash" : "star") {
            Task { await model.setFavourite(target, !starred, given: rowStarred) }
        }
    }
}

/// The star in an album or artist page's header (R7): filled when favourited; text for VoiceOver, a tick on change.
struct FavouriteButton: View {
    @Environment(AppModel.self) private var model
    let target: FavouriteTarget
    private let themed = Themed()

    var body: some View {
        let on = model.isFavourite(target)
        Button { Task { await model.setFavourite(target, !on) } } label: {
            Image(systemName: on ? "star.fill" : "star")
                .font(.title3)
                .foregroundStyle(on ? themed.palette.accentInkColor : themed.palette.inkColor)
                .frame(width: Tokens.minHitSize, height: Tokens.minHitSize)
                .background(themed.palette.solidSurfaceColor, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Favourite")
        .accessibilityValue(on ? "On" : "Off")
        .accessibilityAddTraits(on ? .isSelected : [])
        .sensoryFeedback(.selection, trigger: on)
        .accessibilityIdentifier("favourite-button")
    }
}

extension View {
    /// An album's long-press menu: Play next · Add to queue (R12), then Add to playlist… (all its songs), Favourite and
    /// Reload artwork (offline: only the first two).
    func albumMenu(_ album: Album) -> some View { modifier(LibraryItemMenu(item: .album(album))) }

    /// An artist's long-press menu: Play next · Add to queue (R12), then Favourite and Reload artwork (not offline).
    func artistMenu(_ artist: Artist) -> some View { modifier(LibraryItemMenu(item: .artist(artist))) }
}

private struct LibraryItemMenu: ViewModifier {
    enum Item { case album(Album), artist(Artist) }

    @Environment(AppModel.self) private var model
    let item: Item

    private var id: String {
        switch item {
        case .album(let a): a.id
        case .artist(let a): a.id
        }
    }

    private var coverArtId: String? {
        switch item {
        case .album(let a): a.coverArtId
        case .artist(let a): a.coverArtId
        }
    }

    private var target: FavouriteTarget {
        switch item {
        case .album(let a): .album(a.id)
        case .artist(let a): .artist(a.id)
        }
    }

    private var starred: Bool {
        switch item {
        case .album(let a): a.starred
        case .artist(let a): a.starred
        }
    }

    private var collection: CollectionRef {
        switch item {
        case .album(let a): .album(a.id)
        case .artist(let a): .artist(a.id)
        }
    }

    func body(content: Content) -> some View {
        content.contextMenu {
            // R12 (appraisal §4 group 1): Play next · Add to queue, which ask In order or Shuffled; offline too.
            Section {
                ForEach(QueueMenu.items) { item in
                    Button(item.title, systemImage: item.symbol) { model.perform(item, on: collection) }
                }
            }
            if !model.isOffline, !OfflineCatalog.isLocalId(id) {
                if case .album(let album) = item {   // the appraisal's order (§4): Add to playlist…, Favourite
                    Button(PlaylistCopy.addToPlaylist, systemImage: "text.badge.plus") {
                        Task { await model.askToAddAlbumToPlaylist(album.id) }
                    }
                }
                FavouriteMenuItem(target: target, rowStarred: starred)
                if let coverArtId {
                    Button("Reload artwork", systemImage: "arrow.clockwise") {
                        Task { await model.reloadArtwork(coverArtId) }
                    }
                }
            }
        }
    }
}

/// A page's ⋯ in the toolbar (the UX appraisal's header, R20): the items given, then Reload artwork.
struct PageMoreMenu<Items: View>: View {
    @Environment(AppModel.self) private var model
    let coverArtId: String?
    let identifier: String
    @ViewBuilder let items: Items

    var body: some View {
        Menu {
            items
            if let coverArtId, !model.isOffline {
                Button("Reload artwork", systemImage: "arrow.clockwise") { Task { await model.reloadArtwork(coverArtId) } }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .frame(minWidth: Tokens.minHitSize, minHeight: Tokens.minHitSize)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("More")
        .accessibilityIdentifier(identifier)
    }
}

/// The album page's ⋯: Add to playlist… (every song), Go to artist, Reload artwork.
struct AlbumMoreMenu: View {
    @Environment(AppModel.self) private var model
    let album: Album

    var body: some View {
        PageMoreMenu(coverArtId: album.coverArtId, identifier: "album-more") {
            Button(PlaylistCopy.addToPlaylist, systemImage: "text.badge.plus") {
                model.askToAddToPlaylist((album.songs ?? []).map(\.id))
            }
            .disabled((album.songs ?? []).isEmpty)
            if let artistId = album.artistId {
                NavigationLink(value: Route.artist(id: artistId)) {
                    Label("Go to artist", systemImage: "music.mic")
                }
            }
        }
    }
}
