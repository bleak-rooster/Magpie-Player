import DesignSystem
import MagpieCore
import Playback
import Requests
import SwiftUI

/// Where Now Playing's album and artist go (round 11 R10): the server's pages online; offline the downloaded pages if
/// the song is downloaded, else nowhere (the links are disabled). The artist is the primary (first) artist.
struct NowPlayingLinks: Equatable {
    var album: Route?
    var artist: Route?

    static func resolve(_ song: Song, offline: Bool, catalog: OfflineCatalog?) -> NowPlayingLinks {
        if offline {
            guard let pages = catalog?.pages(ofSong: song.id) else { return NowPlayingLinks() }
            return NowPlayingLinks(album: .album(id: pages.albumId), artist: .artist(id: pages.artistId))
        }
        return NowPlayingLinks(album: song.albumId.map { .album(id: $0) }, artist: song.artistId.map { .artist(id: $0) })
    }
}

/// What the More menu offers for a song (round 11 R9, with the appraisal's groups, R20):
/// 1. a find: Keep · Not for me…;
/// 2. Add to playlist… · Favourite (lyrics mode only, where the star is hidden);
/// 3. Download / Remove download;
/// 4. Go to album · Go to artist;
/// 5. Song info.
/// The sleep timer stays in the bottom row; nothing is shared.
struct NowPlayingMoreItems: Equatable {
    var keep: RequestID?
    var notForMe: RequestID?
    var favourite: Bool?
    var download: DownloadItem
    var album: Route?
    var artist: Route?

    enum DownloadItem: Equatable { case download, remove, cancel }

    /// The items' titles in order, by group (tests; the menu draws the same).
    var titles: [[String]] {
        var groups: [[String]] = []
        let find = [keep.map { _ in "Keep" }, notForMe.map { _ in "Not for me…" }].compactMap { $0 }
        if !find.isEmpty { groups.append(find) }
        groups.append(["Add to playlist…"] + (favourite.map { [$0 ? "Unfavourite" : "Favourite"] } ?? []))
        switch download {
        case .download: groups.append(["Download"])
        case .remove: groups.append(["Remove download"])
        case .cancel: groups.append(["Cancel download"])
        }
        groups.append(["Go to album", "Go to artist"])
        groups.append(["Song info"])
        return groups
    }
}

extension AppModel {
    /// Now Playing's links for `song` as things stand (offline: from what's on the phone).
    func nowPlayingLinks(_ song: Song) async -> NowPlayingLinks {
        let offline = isOffline
        return NowPlayingLinks.resolve(song, offline: offline, catalog: offline ? await offlineCatalog : nil)
    }

    /// The More menu's items for `song`. `lyricsMode`: the star is hidden, so Favourite is in the menu.
    func nowPlayingMoreItems(_ song: Song, lyricsMode: Bool, links: NowPlayingLinks) -> NowPlayingMoreItems {
        let isFind = isFind(song)
        let keep = isFind && findsSetup?.library != nil ? FindsShelf.keepRequest(for: song, in: requests) : nil
        let notForMe = isFind ? FindsShelf.notForMeRequest(for: song, in: requests) : nil
        let download: NowPlayingMoreItems.DownloadItem = switch downloadStatus([song.id]) {
        case .none: .download
        case .downloaded: .remove
        default: .cancel
        }
        return NowPlayingMoreItems(keep: keep, notForMe: notForMe,
                                   favourite: lyricsMode ? isFavourite(.song(song.id)) : nil,
                                   download: download, album: links.album, artist: links.artist)
    }
}

/// Now Playing's ⋯ button in the top bar's right slot (R9), in Signature and Classic alike.
struct NowPlayingMoreMenu: View {
    @Environment(AppModel.self) private var model
    let song: Song
    let lyricsMode: Bool
    let links: NowPlayingLinks
    /// Dismisses Now Playing and pushes `route` onto the current tab (R10).
    let open: (Route) -> Void

    @State private var addingToPlaylist: [String]?
    @State private var showsInfo = false
    @State private var removing: Song?
    @State private var message: String?
    @State private var addingMore: AddFlowRequest?
    @State private var asking: NotForMeConfirm?
    @State private var busy = false

    var body: some View {
        let items = model.nowPlayingMoreItems(song, lyricsMode: lyricsMode, links: links)
        Menu {
            if items.keep != nil || items.notForMe != nil {
                Section {
                    if let id = items.keep {
                        Button("Keep", systemImage: "plus.circle") { keep(id) }.disabled(busy)
                    }
                    if let id = items.notForMe {
                        Button("Not for me…", systemImage: "hand.thumbsdown", role: .destructive) { askNotForMe(id) }
                            .disabled(busy)
                    }
                }
            }
            Section {
                Button("Add to playlist…", systemImage: "text.badge.plus") { addingToPlaylist = [song.id] }
                if let on = items.favourite {
                    Button(on ? "Unfavourite" : "Favourite", systemImage: on ? "star.slash" : "star") {
                        Task { await model.setFavourite(.song(song.id), !on) }
                    }
                }
            }
            Section {
                switch items.download {
                case .download:
                    Button("Download", systemImage: "arrow.down.to.line") { model.download([song], reason: .song) }
                case .remove:
                    Button("Remove download", systemImage: "trash", role: .destructive) { removing = song }
                case .cancel:
                    Button("Cancel download", systemImage: "xmark") { Task { await model.removeSongDownload(song.id) } }
                }
            }
            Section {
                Button("Go to album", systemImage: "square.stack") { if let r = items.album { open(r) } }
                    .disabled(items.album == nil)
                Button("Go to artist", systemImage: "music.microphone") { if let r = items.artist { open(r) } }
                    .disabled(items.artist == nil)
            }
            Section {
                Button("Song info", systemImage: "info.circle") { showsInfo = true }
            }
        } label: {
            Image(systemName: "ellipsis.circle").font(.title3.weight(.semibold))
                .frame(width: Tokens.minHitSize, height: Tokens.minHitSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("More")
        .accessibilityIdentifier("np-more")
        .sheet(isPresented: Binding(get: { addingToPlaylist != nil }, set: { if !$0 { addingToPlaylist = nil } })) {
            AddToPlaylistSheet(songIds: addingToPlaylist ?? [])
        }
        .sheet(isPresented: $showsInfo) { SongInfoSheet(song: song) }
        .addFlow($addingMore) { message = $0.message }
        .songRemovalDialog($removing)
        .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        }
        .confirmationDialog(NotForMeCopy.confirmTitle, isPresented: Binding(get: { asking != nil }, set: { if !$0 { asking = nil } }),
                            titleVisibility: .visible, presenting: asking) { confirm in
            Button(NotForMeCopy.action, role: .destructive) { letGo(confirm) }
            Button("Cancel", role: .cancel) {}
        } message: { confirm in
            Text(confirm.message)
        }
    }

    private func keep(_ id: RequestID) {
        busy = true
        Task {
            let reply = await model.keep(id)
            if reply.bringsInMore {
                addingMore = model.afterKeepRequest(id, artist: song.artist, kept: reply.message)
            } else {
                message = reply.message
            }
            busy = false
        }
    }

    private func askNotForMe(_ id: RequestID) {
        busy = true
        Task {
            switch await model.notForMeAsk(id) {
            case .confirm(let confirm): asking = confirm
            case .message(let text): message = text
            }
            busy = false
        }
    }

    private func letGo(_ confirm: NotForMeConfirm) {
        asking = nil
        busy = true
        Task {
            message = await model.notForMe(confirm)
            busy = false
        }
    }
}

