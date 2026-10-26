import DesignSystem
import MagpieCore
import SwiftUI

/// Artist: name, Play / Shuffle (every album), Popular (hidden when the server has no top songs, A13), Albums.
struct ArtistView: View {
    @Environment(AppModel.self) private var model
    let artistId: String
    @State private var page: Loadable<Page> = .loading
    @State private var topSongs: [Song] = []
    @State private var gathering = false
    private let themed = Themed()

    struct Page {
        var artist: Artist
        var albums: [Album]
    }

    var body: some View {
        ScrollView {
            LoadableView(state: page, retry: load) { page in
                content(page)
            }
        }
        .navigationTitle(page.value?.artist.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .magpieScreen()
        .task { if page.value == nil { await load() } }
    }

    private func content(_ page: Page) -> some View {
        let p = themed.palette
        let albums = page.albums.sorted { ($0.year ?? 0) > ($1.year ?? 0) }
        return VStack(alignment: .leading, spacing: Tokens.Spacing.xxl) {
            VStack(spacing: Tokens.Spacing.m) {
                Artwork(page.artist.coverArtId, side: 180) { SleeveArt(image: $0, side: 180).clipShape(Circle()) }
                Text(page.artist.name).magpieDisplay(.largeTitle).multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                HStack(spacing: Tokens.Spacing.m) {
                    CapsuleButton(gathering ? "Loading…" : "Play", symbol: "play.fill") {
                        Task { await playAll(albums, shuffled: false) }
                    }
                    .frame(maxWidth: .infinity)
                    CapsuleButton("Shuffle", symbol: "shuffle") { Task { await playAll(albums, shuffled: true) } }
                        .frame(maxWidth: .infinity)
                }
                .disabled(albums.isEmpty || gathering)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Tokens.Spacing.margin)

            if !topSongs.isEmpty {
                VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
                    Text("Popular").magpieDisplay(.title2).accessibilityAddTraits(.isHeader)
                        .padding(.horizontal, Tokens.Spacing.margin)
                    ForEach(Array(topSongs.prefix(5).enumerated()), id: \.offset) { index, song in
                        Button { model.play(Array(topSongs.prefix(5)), startAt: index) } label: {
                            Artwork(song.coverArtId, side: 48) { image in
                                SongRow(song: song, state: .library, artwork: image)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(.isButton)
                    }
                }
            }

            VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
                Text("Albums").magpieDisplay(.title2).accessibilityAddTraits(.isHeader)
                    .padding(.horizontal, Tokens.Spacing.largeTitleMargin)
                AlbumGrid(albums: albums) { $0.year.map(String.init) ?? "" }
            }
        }
        .padding(.vertical, Tokens.Spacing.l)
        .foregroundStyle(p.inkColor)
    }

    private func load() async {
        do {
            let (artist, albums) = try await model.request { [artistId] in try await $0.artist(id: artistId) }
            page = .loaded(Page(artist: artist, albums: albums))
            let name = artist.name
            topSongs = (try? await model.request { try await $0.topSongs(artistName: name) }) ?? []
        } catch {
            page = .failed(BrowseErrorCopy.message(for: error))
        }
    }

    /// Fetches every album's tracks (in parallel), then plays them in album order.
    private func playAll(_ albums: [Album], shuffled: Bool) async {
        gathering = true
        defer { gathering = false }
        let ids = albums.map(\.id)
        guard let songs = try? await model.request({ client in
            try await withThrowingTaskGroup(of: (Int, [Song]).self) { group in
                for (i, id) in ids.enumerated() {
                    group.addTask { (i, try await client.album(id: id).songs ?? []) }
                }
                var byIndex: [Int: [Song]] = [:]
                for try await (i, songs) in group { byIndex[i] = songs }
                return ids.indices.flatMap { byIndex[$0] ?? [] }
            }
        }) else { return }
        shuffled ? model.shuffle(songs) : model.play(songs, startAt: 0)
    }
}
