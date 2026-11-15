import AurralKit
import DesignSystem
import MagpieCore
import Playback
import SwiftUI

/// A playlist route: Discover's own page for one of Aurral's flows (online), else the playlist page.
/// Round 28 O3 (owner, 2026-11-15; D343): offline, a flow on the phone opens the playlist page from the phone (O2's
/// `offlineFlowPage`, read from the saved Discover file) with its owner's caption, and none of Discover's actions.
struct PlaylistRouteView: View {
    @Environment(AppModel.self) private var model
    let playlistId: String

    var body: some View {
        if Self.opensDiscoverPage(offline: model.isOffline, isDiscover: model.isDiscoverPlaylist(id: playlistId)) {
            DiscoverPlaylistView(playlistId: playlistId)
        } else {
            PlaylistView(playlistId: playlistId)
        }
    }

    /// Discover's own page only online: offline a flow is the phone's playlist page (D343).
    static func opensDiscoverPage(offline: Bool, isDiscover: Bool) -> Bool { !offline && isDiscover }
}

/// Round 12 Y6 (plan item 7): one Discover playlist. Its songs, each the library's copy when the library has the same
/// recording ("In your library", same place); the worker's progress; Refresh Flow ("Replaces this playlist's songs",
/// refused while a run is under way); "Artists in this playlist" and "Add <artist> to your library" on each row, through
/// Magpie's own Add (its defaults and choices, through the gate). Nothing here changes the playlist on the server.
struct DiscoverPlaylistView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.magpieTheme) private var theme
    let playlistId: String
    /// Round 27 D1 (D285): the saved page at once, the playlist read behind it, library copies filling in place.
    @State private var pageModel: DiscoverPageModel
    @State private var confirmingRefresh = false
    @State private var message: String?
    @State private var showsArtists = false
    @State private var removing: Song?
    @State private var adder = DiscoverArtistAdder()
    @State private var editingFlow: RecipeFlowEditor.Target?
    /// Round 28 O3 (D341): the phone's copy of this flow, shown when its read failed.
    @State private var phoneCopy: OfflinePlaylistPage?
    private let themed = Themed()

    init(playlistId: String) {
        self.playlistId = playlistId
        _pageModel = State(initialValue: DiscoverPageModel(playlistId: playlistId))
    }

    private var page: Loadable<DiscoverPage> { pageModel.state }

    /// Round 28 O3: the read failed with nothing on screen.
    private var failed: Bool { if case .failed = page { true } else { false } }

    /// Round 28 O3 (owner, 2026-11-15; D343): Download (the whole flow to the phone) shows online with a session; another
    /// user's flow may be downloaded too (it's playback, not an Aurral change).
    static func showsDownloadToPhone(_ model: AppModel) -> Bool { model.session != nil && !model.isOffline }

    /// Round 28 O3 (D343): every song the page shows (the library's copy where found, else the Discover copy), with the
    /// flow's reason, its snapshot (kind `flow`, the original→copy map) and its cover, through O2's `downloadFlowToPhone`.
    /// Nothing offline or signed out.
    static func downloadToPhone(_ model: AppModel, _ page: DiscoverPage) {
        guard showsDownloadToPhone(model), !page.entries.isEmpty else { return }
        model.downloadFlowToPhone(page)
    }

    var body: some View {
        List {
            if failed, let phoneCopy {
                phoneCopyContent(phoneCopy)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            } else {
                LoadableView(state: page, retry: load) { page in content(page) }
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
        }
        .task(id: failed) { phoneCopy = await Self.phoneCopy(model, playlistId: playlistId, failed: failed) }
        .transaction { $0.animation = nil }   // Round 27 D1 (D284): a swap behind the owner never animates
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
        .aurralItemMenu(playlistId: playlistId, message: $message)   // R24C (D212): ⋯ › Delete, the user's own
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

    private var flowId: String? { page.value.flatMap { liveFlow($0)?.id } ?? model.discoverFlow(playlistId: playlistId)?.id }
    private var runActive: Bool { flowId.map(model.isFlowRunActive) ?? false }

    /// Round 27 D1 (D283): the page's flow as now known: a page opened from the saved rows before Aurral was read takes
    /// the flow the read finds (Refresh Flow, Download songs) without opening again.
    private func liveFlow(_ page: DiscoverPage) -> AurralFlow? {
        model.discover.status != nil ? model.discoverFlow(playlistId: page.playlist.id) : page.flow
    }

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
                // Round 24 (D205): another user's, under everyone's: who made it.
                OwnerCaption(owner: model.discoverOwnerCaption(playlistId: page.playlist.id), signedInUser: nil)
                Text("\(songs.count) \(songs.count == 1 ? "song" : "songs") · \(minutes) min")
                    .font(theme.numberFont(.footnote)).foregroundStyle(p.ink2Color)
                DownloadMarkLine(model.downloadIndex.mark(playlistId: page.playlist.id, songIds: songs.map(\.id)))   // D343
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
                ActionBar {
                    PlayShuffleButtons(songs: songs, recent: .playlist(page.playlist))   // round 14: quick grid
                    if Self.showsDownloadToPhone(model) { downloadToPhone(page) }   // round 28 O3 (D343)
                }
                if Self.showsDownloadToPhone(model), !page.songs.isEmpty { flowDownloadNote(page) }   // fix round 1 (M2)
                ActionBar {
                    if liveFlow(page) != nil {
                        ActionButton(runActive ? DiscoverCopy.refreshing : DiscoverCopy.refresh, symbol: "arrow.clockwise",
                                     busy: runActive) {
                            confirmingRefresh = true
                        }
                        .disabled(runActive)
                        .accessibilityIdentifier("discover-refresh")
                    }
                    // Round 16: a recipe flow of the user's: Edit flow (its recipe, Delete flow inside).
                    if model.aurralCanManageFlows, let flow = liveFlow(page).flatMap({ model.recipeFlow(id: $0.id) }) {
                        ActionButton(RecipeFlowCopy.editFlow, symbol: "slider.horizontal.3") { editingFlow = .edit(flow) }
                            .accessibilityIdentifier("discover-edit-flow")
                    }
                    ActionButton(DiscoverCopy.artistsInPlaylist, symbol: "person.2") { showsArtists = true }
                        .accessibilityIdentifier("discover-artists")
                    // Round 14 A4 (owner answer 10): a flow made with auto-download off.
                    if let flow = liveFlow(page), flow.autoDownload == false, model.aurralCanAddFlow {
                        ActionButton(DiscoverPagesCopy.downloadSongs, symbol: DiscoverPagesCopy.downloadSongsSymbol) {
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
                    if let flow = liveFlow(page), let note = model.autoDownloadNote(flowId: flow.id) {
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
                            adder.add(model.discoverArtist(for: entry.original, flowId: liveFlow(page)?.id), model: model)
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

    /// Round 28 O3 (D343; fix round 1, design M3, ruling Q1): today's download capsule in both states, as on album and
    /// playlist pages ("Download", `arrow.down.to.line`; then its status, opening Remove download, or Cancel download
    /// while songs come). One ⋯ per page (Delete flow's) is kept, so Remove download lives in the capsule.
    @ViewBuilder private func downloadToPhone(_ page: DiscoverPage) -> some View {
        let songs = page.songs
        DownloadControl(status: flowStatus(page), canStart: !songs.isEmpty, start: { Self.downloadToPhone(model, page) },
                        retry: { model.retryDownloads() },
                        remove: { Task { await model.removeDownload(.playlist(page.playlist.id)) } })
            .accessibilityLabel(OfflinePageCopy.downloadFlowLabel)
            .accessibilityHint(OfflinePageCopy.downloadFlowHint)
    }

    private func flowStatus(_ page: DiscoverPage) -> DownloadStatus {
        model.downloadStatus(page.songs.map(\.id), reason: .playlist(page.playlist.id))
    }

    /// Fix round 1 (design M2): under the bar, how much a download takes before, and that it keeps in step after (Q4).
    @ViewBuilder private func flowDownloadNote(_ page: DiscoverPage) -> some View {
        let text = flowStatus(page) == .none ? OfflinePageCopy.flowAbout(page.songs.count) : OfflinePageCopy.flowFollows
        Text(text)
            .font(.footnote)
            .foregroundStyle(themed.palette.ink2Color)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Tokens.Spacing.margin)
            .accessibilityIdentifier("discover-download-note")
    }

    /// Round 28 O3 (D341; fix round 1, review M3): the phone's copy of a flow whose read failed with nothing on screen
    /// (from the saved Discover file, D335); nil otherwise.
    static func phoneCopy(_ model: AppModel, playlistId: String, failed: Bool) async -> OfflinePlaylistPage? {
        failed ? await model.offlineFlowPage(id: playlistId) : nil
    }

    /// Round 28 O3 (D341): the flow's read failed with nothing on screen and the phone has it: its songs on the phone, in
    /// the flow's order, with the note; Try again and pull to refresh read again.
    @ViewBuilder private func phoneCopyContent(_ copy: OfflinePlaylistPage) -> some View {
        let p = themed.palette
        PhoneCopyNote(retry: { await load(fresh: true) })
        VStack(spacing: Tokens.Spacing.s) {
            Artwork(copy.playlist.coverArtId, side: 220) { SleeveArt(image: $0, side: 220) }
                .padding(.bottom, Tokens.Spacing.s)
            Text(copy.playlist.name).magpieDisplay(.title).multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            OwnerCaption(owner: copy.playlist.owner, signedInUser: nil)
            OnPhoneCountLine(onPhone: copy.onPhone, total: copy.total)
            ActionBar { PlayShuffleButtons(songs: copy.songs, recent: .playlist(copy.playlist)) }
        }
        .padding(.horizontal, Tokens.Spacing.largeTitleMargin)
        .padding(.vertical, Tokens.Spacing.l)
        .frame(maxWidth: .infinity)
        .foregroundStyle(p.inkColor)
        ForEach(Array(copy.songs.enumerated()), id: \.offset) { index, song in
            VStack(spacing: 0) {
                Button { model.play(copy.songs, startAt: index) } label: {
                    Artwork(song.coverArtId, side: 48) { SongRow(song: song, state: .library, artwork: $0) }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("track-\(index)")
                .contextMenu { PhoneSongMenuItems(song: song, removing: $removing) }   // fix round 1 (design M10)
                Divider().overlay(p.sepColor).padding(.leading, 76)
            }
            .foregroundStyle(p.inkColor)
            .songSwipeActions(song, in: .list, destructive: nil)
        }
    }

    /// The worker's progress while a run is under way, else Aurral's own line ("Next update in 5 days").
    private func statusLine(_ page: DiscoverPage) -> (text: String, symbol: String)? {
        guard let flowId = liveFlow(page)?.id else { return nil }
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

    /// Round 27 D1 (D285, supersedes the unbounded wait for the whole Discover read): the saved page shows at once; the
    /// read is waited for at most `discoverWait` only when nothing is known. Round 13 Z2: a load cut short is never an
    /// error; a failure with a page on screen is quiet unless the owner pulled to refresh.
    private func load(fresh: Bool) async {
        await pageModel.load(model, fresh: fresh)
    }
}

/// Library › Discover: Aurral's flow playlists.
struct DiscoverListView: View {
    @Environment(AppModel.self) private var model
    /// Round 26 L (D271): playlists and items. Round 27 D1 (D283, D284): the saved rows at once, swapped in place.
    @State private var list = DiscoverListModel()
    @State private var editingFlow: RecipeFlowEditor.Target?
    @State private var deletingFlow: AurralFlow?
    @State private var message: String?
    private let themed = Themed()

    private var playlists: Loadable<[DiscoverRow]> { list.rows }

    /// Round 28 O3 (owner, 2026-11-15, item 1: "flows"; D340, D343): offline, the flows on the phone (O2's
    /// `offlineFlows`, from the saved Discover file, D185/D189/D190 as saved), each opening from the phone; nothing that
    /// needs Aurral (Your flows' recipes, For you, Browse more).
    var body: some View {
        if model.isOffline { OfflineFlowsList() } else { online }
    }

    /// Round 28 O3 (D343): the flows Library › Discover lists offline; none without Aurral.
    static func offlineFlows(_ model: AppModel) async -> [Playlist] { await model.offlineFlows() }

    /// Fix round 1 (review M6): one offline row: the flow, its songs on the phone and how many it has.
    struct OfflineRow { var playlist: Playlist; var onPhone: Int; var total: Int? }

    /// Fix round 1 (review M6): the flows on the phone with their counts (each flow's page from the saved file).
    static func offlineRows(_ model: AppModel) async -> [OfflineRow] {
        var rows: [OfflineRow] = []
        for flow in await model.offlineFlows() {
            let page = await model.offlineFlowPage(id: flow.id)
            rows.append(OfflineRow(playlist: flow, onPhone: page?.onPhone ?? flow.songCount, total: page?.total))
        }
        return rows
    }

    private var online: some View {
        List {
            YourFlowsSection()   // round 16: the user's own recipe flows (New flow, Edit flow, Delete flow)
            LoadableView(state: playlists, retry: load) { rows in
                ForEach(rows) { row in
                    switch row.link {
                    case .playlist(let playlist): playlistRow(playlist)
                    case .item(let item, let mine): itemRow(item, mine: mine, row: row)
                    }
                }
            }
            .listRowSeparatorTint(themed.palette.sepColor)
            .transaction { $0.animation = nil }   // Round 27 D1 (D284): a swap behind the owner never animates
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
                    let gone = Set(model.discover.playlists.filter { $0.flow.id == flow.id }.map { "playlist:" + $0.playlist.id })
                    do {
                        try await model.deleteRecipeFlow(flow)
                        list.remove(gone)
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
        .onChange(of: model.discover.itemRows.map(\.item.id)) { Task { await load() } }   // R26L (D271)
        .onChange(of: model.discover.hiddenPlaylistIds) { Task { await load() } }   // R26L fix round 1 (M2, D273)
        .onChange(of: model.discover.everyoneRevision) { Task { await load() } }   // R23F (D190)
        .onChange(of: model.discover.rowsRevision) { Task { await load() } }   // Round 27 D1 (D284): a read changed them
    }

    /// One of Aurral's playlists: opens its page and plays.
    @ViewBuilder private func playlistRow(_ playlist: Playlist) -> some View {
        // Round 16 (owner): a recipe flow shows once, as this row: greyed while its songs download, with
        // Edit flow and Delete flow on a long press or swipe.
        let flow = model.aurralCanManageFlows ? model.recipeFlow(playlistId: playlist.id) : nil
        let download = flow.flatMap(model.recipeFlowDownload)
        NavigationLink(value: Route.playlist(id: playlist.id)) {
            HStack(spacing: Tokens.Spacing.m) {
                Artwork(playlist.coverArtId, side: 56) { SleeveArt(image: $0, side: 56) }
                VStack(alignment: .leading, spacing: 1) {
                    Text(playlist.name).font(.body)
                    // Round 24 (D205): another user's, under everyone's: who made it ("made by sam").
                    OwnerCaption(owner: model.discoverOwnerCaption(playlistId: playlist.id), signedInUser: nil)
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

    /// Round 26 L (D271): an Aurral item no Navidrome playlist is known to be. It doesn't open (nothing of it plays
    /// yet) and says why; another user's says whose ("sam") under everyone's.
    private func itemRow(_ item: AurralFlow, mine: Bool, row: DiscoverRow) -> some View {
        let state = model.discoverItemState(item, mine: mine)
        return HStack(spacing: Tokens.Spacing.m) {
            Image(systemName: "music.note.list").font(.title3).frame(width: 56, height: 56)
                .foregroundStyle(themed.palette.ink2Color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).font(.body)
                OwnerCaption(owner: model.discoverOwnerCaption(row: row), signedInUser: nil)
                Label(state.text, systemImage: state.symbol)
                    .font(.footnote).foregroundStyle(themed.palette.ink2Color)
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: Tokens.minHitSize)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("discover-item-\(item.id)")
        .listRowBackground(Color.clear)
    }

    private func load() async {
        await list.load(model)
    }
}

/// Round 28 O3 (owner, 2026-11-15, item 1: "flows"; D340, D343): Library › Discover offline: the flows holding a song on
/// the phone, in Discover's order, each with its owner's caption (D205) and how many of its songs are here; a row opens
/// the flow's page from the phone. Nothing on the phone says "Nothing downloaded yet".
/// Fix round 1 (review M6, design H3): each row says "<n> of <m> songs on this phone"; empty, "No flows on this phone"
/// (or "Nothing downloaded yet" with nothing downloaded).
private struct OfflineFlowsList: View {
    @Environment(AppModel.self) private var model
    @State private var rows: [DiscoverListView.OfflineRow]?
    @State private var phoneEmpty = false
    private let themed = Themed()

    var body: some View {
        List {
            ForEach(rows ?? [], id: \.playlist.id) { row in
                NavigationLink(value: Route.playlist(id: row.playlist.id)) {
                    HStack(spacing: Tokens.Spacing.m) {
                        Artwork(row.playlist.coverArtId, side: 56) { SleeveArt(image: $0, side: 56) }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.playlist.name).font(.body)
                            OwnerCaption(owner: row.playlist.owner, signedInUser: nil)
                            Label(OfflinePageCopy.onPhone(row.onPhone, of: row.total)
                                      ?? (row.onPhone == 1 ? "1 song" : "\(row.onPhone) songs"),
                                  systemImage: OfflinePageCopy.onPhoneSymbol)
                                .font(.footnote).foregroundStyle(themed.palette.ink2Color)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
                .listRowBackground(Color.clear)
            }
            .listRowSeparatorTint(themed.palette.sepColor)
        }
        .listStyle(.plain)
        .overlay {
            if rows == nil {
                ProgressView()
            } else if rows?.isEmpty == true {
                let empty = OfflineLists.empty(.flows, phoneEmpty: phoneEmpty)
                NothingDownloadedView(title: empty.title, detail: empty.detail)
            }
        }
        .navigationTitle(DiscoverCopy.title)
        .navigationBarTitleDisplayMode(.inline)
        .magpieScreen()
        .task(id: model.offlinePageKey) {
            phoneEmpty = await OfflineLists.phoneEmpty(model)
            rows = await DiscoverListView.offlineRows(model)
        }
    }
}
