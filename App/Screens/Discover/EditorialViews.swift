import AurralKit
import DesignSystem
import MagpieCore
import Playback
import SwiftUI

/// A Discover playlist's card (For you, a genre shelf, Popular playlists).
struct PlaylistCard: View {
    let playlist: PlaylistSummary
    private let themed = Themed()

    var body: some View {
        NavigationLink(value: Route.discoverPlaylist(id: playlist.id)) {
            VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                AurralArt(image: playlist.artwork, side: 140)
                Text(playlist.name).font(.subheadline.weight(.semibold)).lineLimit(2)
                Text(playlist.curator ?? DiscoverPagesCopy.songs(playlist.trackCount))
                    .font(.footnote).foregroundStyle(themed.palette.ink2Color).lineLimit(1)
            }
            .frame(width: 140, alignment: .leading)
            .accessibilityElement(children: .combine)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("discover-playlist-\(playlist.id)")
    }
}

/// Library › Discover's lower half (owner answer 1): For you underneath the owner's flows, then Browse more playlists.
/// Hidden when the server has no Discover playlists (2.10, or the feature off).
struct ForYouSection: View {
    @Environment(AppModel.self) private var model

    private var feeds: AurralFeeds { model.aurralFeeds }

    var body: some View {
        if feeds.can.editorial {
            VStack(alignment: .leading, spacing: Tokens.Spacing.l) {
                if let forYou = feeds.editorial?.forYou, !forYou.isEmpty {
                    ShelfSection(DiscoverPagesCopy.forYou) {
                        ForEach(forYou, id: \.id) { PlaylistCard(playlist: $0) }
                    }
                } else if feeds.editorial == nil {
                    PageSectionTitle(title: DiscoverPagesCopy.forYou)
                    UpdatingCard()
                }
                NavigationLink(value: Route.browsePlaylists) {
                    Label(DiscoverPagesCopy.browseMore, systemImage: "square.grid.2x2")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: Tokens.minHitSize, alignment: .leading)
                        .padding(.horizontal, Tokens.Spacing.margin)
                }
                .accessibilityIdentifier("discover-browse-more")
            }
            .task { await feeds.refresh(.editorial) }
        }
    }
}

/// Discover › Browse more playlists: For you, then one shelf per genre.
struct BrowsePlaylistsView: View {
    @Environment(AppModel.self) private var model
    private var feeds: AurralFeeds { model.aurralFeeds }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Tokens.Spacing.xxl) {
                if let editorial = feeds.editorial {
                    if !editorial.forYou.isEmpty {
                        ShelfSection(DiscoverPagesCopy.forYou) {
                            ForEach(editorial.forYou, id: \.id) { PlaylistCard(playlist: $0) }
                        }
                    }
                    ForEach(editorial.genres, id: \.id) { shelf in
                        ShelfSection(shelf.name) {
                            ForEach(shelf.playlists, id: \.id) { PlaylistCard(playlist: $0) }
                        }
                    }
                } else {
                    UpdatingCard()
                }
            }
            .padding(.vertical, Tokens.Spacing.l)
        }
        .refreshable { await RefreshSafety.run { await feeds.refresh(.editorial, force: true) } }
        .navigationTitle(DiscoverPagesCopy.browseMore)
        .navigationBarTitleDisplayMode(.inline)
        .magpieScreen()
        .task { await feeds.refresh(.editorial) }
    }
}

/// One Discover playlist: cover, curator and song count, Play previews and Add flow, then its songs (the library's
/// copies play the real file; the others have previews).
struct EditorialPlaylistView: View {
    @Environment(AppModel.self) private var model
    let playlistId: String
    @State private var page: Loadable<EditorialPage> = .loading
    private let themed = Themed()

    var body: some View {
        ScrollView {
            LoadableView(state: page, retry: load) { page in content(page) }
                .padding(.vertical, Tokens.Spacing.l)
        }
        .refreshable { await RefreshSafety.run { await load() } }
        .navigationTitle(page.value?.name ?? DiscoverCopy.title)
        .navigationBarTitleDisplayMode(.inline)
        .magpieScreen()
        .task { await load() }
    }

    @ViewBuilder private func content(_ page: EditorialPage) -> some View {
        VStack(spacing: Tokens.Spacing.l) {
            VStack(spacing: Tokens.Spacing.s) {
                AurralArt(image: page.artwork, side: 220)
                    .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
                    .padding(.bottom, Tokens.Spacing.s)
                Text(page.name).magpieDisplay(.title).multilineTextAlignment(.center).accessibilityAddTraits(.isHeader)
                if let curator = page.curator {
                    Text(DiscoverPagesCopy.curated(by: curator)).font(.subheadline).foregroundStyle(themed.palette.ink2Color)
                }
                Text(DiscoverPagesCopy.songs(page.songs.count)).font(.footnote).foregroundStyle(themed.palette.ink2Color)
                    .accessibilityIdentifier("discover-playlist-count")
            }
            .padding(.horizontal, Tokens.Spacing.largeTitleMargin)
            HStack(spacing: Tokens.Spacing.s) {
                PlayPreviewsButton(items: page.songs.map(model.previewItem(for:)))
                AddFlowControl(deezerPlaylistId: page.id, libraryPlaylistId: page.libraryPlaylistId)
            }
            ChartSongList(songs: page.songs, identifier: "discover-song")
        }
        .frame(maxWidth: .infinity)
        .foregroundStyle(themed.palette.inkColor)
    }

    private func load() async {
        do { page = .loaded(try await model.editorialPage(id: playlistId)) } catch {
            page = page.failing(error, noticeTo: model)
        }
    }
}

/// Add flow (owner answer 10): hidden without accessFlow; Add flow → Adding → Downloading 12/40 (or Waiting for a
/// downloader) → In your flows. Before adding without a download source it explains first. While open, progress is read
/// every 30 s; a song that couldn't download offers Retry.
struct AddFlowControl: View {
    @Environment(AppModel.self) private var model
    let deezerPlaylistId: String
    let libraryPlaylistId: String?
    @State private var adding = false
    @State private var added: String?
    @State private var progress: SyncedProgress?
    @State private var explaining = false
    @State private var message: String?

    private var playlistId: String? { added ?? model.aurralFeeds.added[deezerPlaylistId] ?? libraryPlaylistId }

    private var phase: AddFlowPhase {
        AppModel.addFlowPhase(canAdd: model.aurralCanAddFlow, adding: adding, playlistId: playlistId, progress: progress,
                              hasDownloader: model.aurralHasDownloader)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            if let label = phase.label {
                switch phase {
                case .ready:
                    CapsuleButton(label, symbol: "plus.circle") {
                        if model.aurralHasDownloader == false { explaining = true } else { Task { await add() } }
                    }
                    .accessibilityIdentifier("add-flow")
                default:
                    Label(label, systemImage: phase == .inYourFlows ? "checkmark.circle" : "arrow.down.circle.dotted")
                        .font(.subheadline.weight(.semibold))
                        .accessibilityIdentifier("add-flow-state")
                }
            }
            if let progress, let playlistId, model.aurralCanAddFlow {
                ForEach(progress.failed, id: \.id) { job in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(job.trackName).font(.footnote.weight(.semibold))
                            Text(DiscoverPagesCopy.couldntDownload).font(.caption)
                        }
                        Spacer()
                        Button(DiscoverPagesCopy.retry) { Task { await retry(job, playlistId) } }
                            .font(.footnote.weight(.semibold))
                            .accessibilityIdentifier("retry-\(job.id)")
                    }
                }
            }
        }
        .alert(DiscoverPagesCopy.noDownloaderTitle, isPresented: $explaining) {
            Button(DiscoverPagesCopy.addFlow) { Task { await add() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(DiscoverPagesCopy.noDownloader)
        }
        .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        }
        // Progress while visible: at once, then every 30 s while songs are still to come.
        .task(id: playlistId) {
            guard let playlistId else { return }
            while !Task.isCancelled {
                progress = await model.syncedProgress(playlistId: playlistId)
                guard (progress?.waiting ?? 0) > 0 else { return }
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    private func add() async {
        adding = true
        defer { adding = false }
        do {
            let result = try await model.addFlow(deezerPlaylistId: deezerPlaylistId)
            added = result.playlistId
        } catch {
            message = DiscoverCopy.message(for: error)
        }
    }

    private func retry(_ job: AurralJob, _ playlistId: String) async {
        do {
            try await model.retrySong(playlistId: playlistId, job: job)
            progress = await model.syncedProgress(playlistId: playlistId)
        } catch {
            message = DiscoverCopy.message(for: error)
        }
    }
}
