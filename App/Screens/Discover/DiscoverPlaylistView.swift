import AurralKit
import DesignSystem
import MagpieCore
import Playback
import SwiftUI

/// A playlist route: Discover's own page for one of Aurral's flows (online), else the playlist page.
struct PlaylistRouteView: View {
    @Environment(AppModel.self) private var model
    let playlistId: String

    var body: some View {
        if !model.isOffline, model.isDiscoverPlaylist(id: playlistId) {
            DiscoverPlaylistView(playlistId: playlistId)
        } else {
            PlaylistView(playlistId: playlistId)
        }
    }
}

/// Round 12 Y6 (plan item 7): one Discover playlist. Its songs, each the library's copy when the library has the same
/// recording ("In your library", same place); the worker's progress; Refresh Flow ("Replaces this playlist's songs",
/// refused while a run is under way); "Artists in this playlist" and "Add <artist> to your library" on each row, through
/// Magpie's own Add (its defaults and choices, through the gate). Nothing here changes the playlist on the server.
struct DiscoverPlaylistView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.magpieTheme) private var theme
    let playlistId: String
    @State private var page: Loadable<DiscoverPage> = .loading
    @State private var confirmingRefresh = false
    @State private var message: String?
    @State private var showsArtists = false
    @State private var removing: Song?
    @State private var adder = DiscoverArtistAdder()
    private let themed = Themed()

    var body: some View {
        List {
            LoadableView(state: page, retry: load) { page in content(page) }
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .refreshable {
            await RefreshSafety.run {   // Round 13 Z2
                await model.refreshDiscover(force: true)
                await load(fresh: true)
            }
        }
        .navigationTitle(page.value?.playlist.name ?? DiscoverCopy.title)
        .navigationBarTitleDisplayMode(.inline)
        .magpieScreen()
        .songRemovalDialog($removing)
        .confirmationDialog("\(DiscoverCopy.refresh)?", isPresented: $confirmingRefresh, titleVisibility: .visible) {
            Button(DiscoverCopy.refresh, role: .destructive) { Task { await refresh() } }
                .accessibilityIdentifier("discover-refresh-confirm")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(DiscoverCopy.refreshConfirm)
        }
        .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        }
        .sheet(isPresented: $showsArtists) {
            if let page = page.value {
                DiscoverArtistsView(artists: model.discoverArtists(page), adder: adder)
            }
        }
        .addFlow($adder.addFlow) { outcome in
            adder.finished(outcome)
            message = outcome.message
        }
        .onChange(of: adder.message) { if let text = adder.message { message = text; adder.message = nil } }
        .task { await load() }
        // While a run is under way, its progress every 5 s; when it ends, the new songs.
        .task(id: runActive) {
            guard runActive else { return }
            while !Task.isCancelled, runActive {
                try? await Task.sleep(for: .seconds(5))
                await model.refreshDiscoverStatus()
            }
            if !Task.isCancelled { await load() }
        }
    }

    private var flowId: String? { page.value?.flow?.id ?? model.discoverFlow(playlistId: playlistId)?.id }
    private var runActive: Bool { flowId.map(model.isFlowRunActive) ?? false }

    @ViewBuilder private func content(_ page: DiscoverPage) -> some View {
        let p = themed.palette
        let songs = page.songs
        let minutes = DurationText.minutes(songs.reduce(0) { $0 + $1.duration })
        VStack(spacing: Tokens.Spacing.l) {
            VStack(spacing: Tokens.Spacing.s) {
                Artwork(page.playlist.coverArtId, side: 220) { SleeveArt(image: $0, side: 220) }
                    .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
                    .padding(.bottom, Tokens.Spacing.s)
                Text(page.playlist.name).magpieDisplay(.title).multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Text("\(songs.count) \(songs.count == 1 ? "song" : "songs") · \(minutes) min")
                    .font(theme.numberFont(.footnote)).foregroundStyle(p.ink2Color)
                if let line = statusLine(page) {
                    Label(line.text, systemImage: line.symbol).font(.footnote).foregroundStyle(p.ink2Color)
                        .accessibilityIdentifier("discover-progress")
                }
            }
            .padding(.horizontal, Tokens.Spacing.largeTitleMargin)
            // Y7 phase 2: the same ActionBars as every page: Play and Shuffle, then this page's own actions (tinted).
            VStack(spacing: Tokens.Spacing.s) {
                ActionBar { PlayShuffleButtons(songs: songs) }
                ActionBar {
                    if page.flow != nil {
                        ActionButton(runActive ? DiscoverCopy.refreshing : DiscoverCopy.refresh, symbol: "arrow.clockwise",
                                     busy: runActive) {
                            confirmingRefresh = true
                        }
                        .disabled(runActive)
                        .accessibilityIdentifier("discover-refresh")
                    }
                    ActionButton(DiscoverCopy.artistsInPlaylist, symbol: "person.2") { showsArtists = true }
                        .accessibilityIdentifier("discover-artists")
                }
            }
        }
        .padding(.vertical, Tokens.Spacing.l)
        .frame(maxWidth: .infinity)
        .foregroundStyle(p.inkColor)

        ForEach(Array(page.entries.enumerated()), id: \.offset) { index, entry in
            VStack(alignment: .leading, spacing: 0) {
                Button { model.play(songs, startAt: index) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Artwork(entry.song.coverArtId, side: 48) { image in
                            SongRow(song: entry.song, state: .library, artwork: image)
                        }
                        if entry.inYourLibrary {
                            Label(DiscoverCopy.inYourLibrary, systemImage: "checkmark.circle")
                                .font(.caption).foregroundStyle(p.ink2Color)
                                .padding(.leading, 76).padding(.bottom, Tokens.Spacing.xs)
                                .accessibilityIdentifier("discover-in-library-\(index)")
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("track-\(index)")
                .contextMenu {
                    SongQueueMenuItems(song: entry.song)
                    SongDownloadMenuItem(song: entry.song, removing: $removing)
                    if !entry.inYourLibrary, model.lidarr != nil {
                        Button {
                            adder.add(model.discoverArtist(for: entry.original, flowId: page.flow?.id), model: model)
                        } label: {
                            Label(DiscoverCopy.addArtist(entry.original.artist), systemImage: "plus")
                        }
                    }
                }
                Divider().overlay(p.sepColor).padding(.leading, 76)
            }
            .foregroundStyle(p.inkColor)
            .songSwipeActions(entry.song, in: .list, destructive: nil)
        }
        Color.clear.frame(height: Tokens.Spacing.l)
    }

    /// The worker's progress while a run is under way, else Aurral's own line ("Next update in 5 days").
    private func statusLine(_ page: DiscoverPage) -> (text: String, symbol: String)? {
        guard let flowId = page.flow?.id else { return nil }
        if model.isFlowRunActive(flowId) {
            if let progress = model.discover.status?.progress(flowId: flowId) {
                return (DiscoverCopy.progress(progress), "arrow.down.circle.dotted")
            }
            return (DiscoverCopy.refreshing, "arrow.down.circle.dotted")
        }
        return model.discover.status?.hint?.message.map { ($0, "calendar") }
    }

    private func refresh() async {
        guard let flowId else { return }
        do { try await model.refreshFlow(flowId) } catch { message = DiscoverCopy.message(for: error) }
    }

    private func load() async { await load(fresh: false) }

    private func load(fresh: Bool) async {
        do {
            if model.discover.playlists.isEmpty { await model.refreshDiscover() }
            page = .loaded(try await model.discoverPage(playlistId: playlistId, fresh: fresh))
        } catch {
            page = page.failing(error)   // Round 13 Z2: also never for a load cut short
        }
    }
}

/// Library › Discover: Aurral's flow playlists.
struct DiscoverListView: View {
    @Environment(AppModel.self) private var model
    @State private var playlists: Loadable<[Playlist]> = .loading
    private let themed = Themed()

    var body: some View {
        List {
            LoadableView(state: playlists, retry: load) { playlists in
                ForEach(playlists, id: \.id) { playlist in
                    NavigationLink(value: Route.playlist(id: playlist.id)) {
                        HStack(spacing: Tokens.Spacing.m) {
                            Artwork(playlist.coverArtId, side: 56) { SleeveArt(image: $0, side: 56) }
                            VStack(alignment: .leading, spacing: 1) {
                                Text(playlist.name).font(.body)
                                Text(playlist.songCount == 1 ? "1 song" : "\(playlist.songCount) songs")
                                    .font(.footnote).foregroundStyle(themed.palette.ink2Color)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                    .listRowBackground(Color.clear)
                }
            }
            .listRowSeparatorTint(themed.palette.sepColor)
        }
        .listStyle(.plain)
        .overlay {
            if playlists.value?.isEmpty == true {
                ContentUnavailableView(DiscoverCopy.empty, systemImage: LibraryRow.discover.symbol)
            }
        }
        .refreshable {
            await RefreshSafety.run {   // Round 13 Z2
                await model.refreshDiscover(force: true)
                await load()
            }
        }
        .navigationTitle(DiscoverCopy.title)
        .navigationBarTitleDisplayMode(.inline)
        .magpieScreen()
        .task { await load() }
    }

    private func load() async {
        do { playlists = .loaded(try await model.discoverPlaylists()) } catch {
            playlists = playlists.failing(error)   // Round 13 Z2: also never for a load cut short
        }
    }
}
