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
    @State private var editingFlow: RecipeFlowEditor.Target?
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
        .sheet(item: $editingFlow) { RecipeFlowEditor(target: $0) }   // round 16
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
                // Round 14 A4 fix round 1 (M7): Add flow's playlist shows its download progress here too.
                if model.aurralCanAddFlow, let synced = model.discoverSyncedPlaylist(playlistId: page.playlist.id) {
                    SyncedProgressLine(playlistId: synced.id)
                }
                if let line = statusLine(page) {
                    Label(line.text, systemImage: line.symbol).font(.footnote).foregroundStyle(p.ink2Color)
                        .accessibilityIdentifier("discover-progress")
                }
            }
            .padding(.horizontal, Tokens.Spacing.largeTitleMargin)
            // Y7 phase 2: the same ActionBars as every page: Play and Shuffle, then this page's own actions (tinted).
            VStack(spacing: Tokens.Spacing.s) {
                ActionBar { PlayShuffleButtons(songs: songs, recent: .playlist(page.playlist)) }   // round 14: quick grid
                ActionBar {
                    if page.flow != nil {
                        ActionButton(runActive ? DiscoverCopy.refreshing : DiscoverCopy.refresh, symbol: "arrow.clockwise",
                                     busy: runActive) {
                            confirmingRefresh = true
                        }
                        .disabled(runActive)
                        .accessibilityIdentifier("discover-refresh")
                    }
                    // Round 16: a recipe flow of the user's: Edit flow (its recipe, Delete flow inside).
                    if model.aurralCanManageFlows, let flow = page.flow.flatMap({ model.recipeFlow(id: $0.id) }) {
                        ActionButton(RecipeFlowCopy.editFlow, symbol: "slider.horizontal.3") { editingFlow = .edit(flow) }
                            .accessibilityIdentifier("discover-edit-flow")
                    }
                    ActionButton(DiscoverCopy.artistsInPlaylist, symbol: "person.2") { showsArtists = true }
                        .accessibilityIdentifier("discover-artists")
                    // Round 14 A4 (owner answer 10): a flow made with auto-download off.
                    if let flow = page.flow, flow.autoDownload == false, model.aurralCanAddFlow {
                        ActionButton(DiscoverPagesCopy.downloadSongs, symbol: "arrow.down.circle") {
                            Task {
                                do { try await model.downloadFlowSongs(flowId: flow.id) } catch {
                                    message = error as? AurralError == .noDownloader ? DiscoverPagesCopy.noDownloader
                                        : DiscoverCopy.message(for: error)
                                }
                            }
                        }
                        .accessibilityIdentifier("discover-download-songs")
                    }
                    // Round 22 R22A (D186): its songs couldn't start by themselves; said quietly, here only.
                    if let flow = page.flow, let note = model.autoDownloadNote(flowId: flow.id) {
                        Label(AurralAutoDownloadCopy.note(note), systemImage: "info.circle")
                            .font(.footnote).foregroundStyle(p.ink2Color)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, Tokens.Spacing.l)
                            .accessibilityIdentifier("discover-auto-download-note")
                    }
                }
                // Round 23 R23F (D199): the user's own flow's or playlist's missing songs, searched for again.
                SearchAgainSection(playlistId: page.playlist.id,
                                   runActive: model.searchAgainFlow(playlistId: page.playlist.id)
                                       .map { model.isFlowRunActive($0.id) } ?? false)
            }
        }
        .padding(.vertical, Tokens.Spacing.l)
        .frame(maxWidth: .infinity)
        .foregroundStyle(p.inkColor)

        ForEach(Array(page.entries.enumerated()), id: \.offset) { index, entry in
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    model.noteRecentlyPlayed(.playlist(page.playlist))   // round 14: Home's quick grid
                    model.play(songs, startAt: index)
                } label: {
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
            page = page.failing(error, noticeTo: model)   // Round 13 Z2: also never for a load cut short
        }
    }
}

/// Library › Discover: Aurral's flow playlists.
struct DiscoverListView: View {
    @Environment(AppModel.self) private var model
    @State private var playlists: Loadable<[Playlist]> = .loading
    @State private var editingFlow: RecipeFlowEditor.Target?
    @State private var deletingFlow: AurralFlow?
    @State private var message: String?
    private let themed = Themed()

    var body: some View {
        List {
            YourFlowsSection()   // round 16: the user's own recipe flows (New flow, Edit flow, Delete flow)
            LoadableView(state: playlists, retry: load) { playlists in
                ForEach(playlists, id: \.id) { playlist in
                    // Round 16 (owner): a recipe flow shows once, as this row: greyed while its songs download, with
                    // Edit flow and Delete flow on a long press or swipe.
                    let flow = model.aurralCanManageFlows ? model.recipeFlow(playlistId: playlist.id) : nil
                    let download = flow.flatMap(model.recipeFlowDownload)
                    NavigationLink(value: Route.playlist(id: playlist.id)) {
                        HStack(spacing: Tokens.Spacing.m) {
                            Artwork(playlist.coverArtId, side: 56) { SleeveArt(image: $0, side: 56) }
                            VStack(alignment: .leading, spacing: 1) {
                                Text(playlist.name).font(.body)
                                if let download {
                                    Label(download.text, systemImage: "arrow.down.circle.dotted")
                                        .font(.footnote).foregroundStyle(themed.palette.ink2Color)
                                } else {
                                    Text(playlist.songCount == 1 ? "1 song" : "\(playlist.songCount) songs")
                                        .font(.footnote).foregroundStyle(themed.palette.ink2Color)
                                }
                            }
                        }
                        .opacity(download == nil ? 1 : 0.45)
                        .accessibilityElement(children: .combine)
                    }
                    .listRowBackground(Color.clear)
                    .contextMenu {
                        if let flow {
                            Button(RecipeFlowCopy.editFlow, systemImage: "slider.horizontal.3") { editingFlow = .edit(flow) }
                            Button(RecipeFlowCopy.deleteFlow, systemImage: "trash", role: .destructive) { deletingFlow = flow }
                        }
                    }
                    .swipeActions {
                        if let flow {
                            Button(RecipeFlowCopy.deleteFlow, role: .destructive) { deletingFlow = flow }
                            Button(RecipeFlowCopy.editFlow) { editingFlow = .edit(flow) }.tint(.accentColor)
                        }
                    }
                }
            }
            .listRowSeparatorTint(themed.palette.sepColor)
            // Round 14 A4 (owner answer 1): For you underneath, then Browse more playlists.
            ForYouSection()
                .padding(.vertical, Tokens.Spacing.l)
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .overlay {
            if playlists.value?.isEmpty == true, model.aurralFeeds?.can.editorial != true {
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
        .sheet(item: $editingFlow) { RecipeFlowEditor(target: $0) }
        .confirmationDialog(RecipeFlowCopy.deleteQuestion, isPresented: Binding(get: { deletingFlow != nil },
                                                                                set: { if !$0 { deletingFlow = nil } }),
                            titleVisibility: .visible, presenting: deletingFlow) { flow in
            Button(RecipeFlowCopy.deleteFlow, role: .destructive) {
                Task {
                    let gone = Set(model.discover.playlists.filter { $0.flow.id == flow.id }.map(\.playlist.id))
                    do {
                        try await model.deleteRecipeFlow(flow)
                        if let list = playlists.value { playlists = .loaded(list.filter { !gone.contains($0.id) }) }
                    } catch { message = DiscoverCopy.message(for: error) }
                }
            }
        } message: { _ in
            Text(RecipeFlowCopy.deleteNote)
        }
        .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        }
        .task { await load() }
        // Round 16: a flow's playlist joins (or leaves) as the server publishes it.
        .onChange(of: model.discover.playlists.map(\.playlist.id)) { Task { await load() } }
        .onChange(of: model.discover.everyoneRevision) { Task { await load() } }   // R23F (D190)
    }

    private func load() async {
        do { playlists = .loaded(try await model.discoverPlaylists()) } catch {
            playlists = playlists.failing(error, noticeTo: model)   // Round 13 Z2: also never for a load cut short
        }
    }
}
