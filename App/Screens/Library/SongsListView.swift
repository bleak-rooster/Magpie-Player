import DesignSystem
import MagpieCore
import SwiftUI

/// Library › Songs (spec §3, Task 21): every song, A–Z by title, `AppModel.songsPageSize` at a time; the next page is
/// read when the last row appears. A row plays the songs read so far, from that song.
struct SongsListView: View {
    @Environment(AppModel.self) private var model
    @State private var songs: Loadable<[Song]> = .loading
    /// The next page to read.
    @State private var nextPage = 1
    @State private var exhausted = false
    @State private var loadingMore = false
    @State private var moreError: String?
    @State private var removing: Song?
    private let themed = Themed()

    var body: some View {
        ScrollView {
            LoadableView(state: songs, retry: loadFirst) { songs in
                if songs.isEmpty {
                    ContentUnavailableView("No songs yet", systemImage: "music.note",
                                           description: Text("Songs show up here once your server has some."))
                } else {
                    list(songs)
                }
            }
        }
        .navigationTitle("Songs")
        .navigationBarTitleDisplayMode(.inline)
        .magpieScreen()
        .songRemovalDialog($removing)
        .task { if songs.value == nil { await loadFirst() } }
    }

    private func list(_ songs: [Song]) -> some View {
        let p = themed.palette
        return LazyVStack(spacing: 0) {
            ForEach(Array(songs.enumerated()), id: \.offset) { index, song in
                Button { model.play(songs, startAt: index) } label: {
                    Artwork(song.coverArtId, side: 48) { image in
                        SongRow(song: song, state: .library, artwork: image)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("song-\(index)")
                .contextMenu { SongDownloadMenuItem(song: song, removing: $removing) }
                .onAppear { if index == songs.count - 1 { Task { await loadMore() } } }
                Divider().overlay(p.sepColor).padding(.leading, 76)
            }
            if let moreError {
                VStack(spacing: Tokens.Spacing.s) {
                    Text(moreError).font(.footnote).multilineTextAlignment(.center)
                    Button("Try again") { Task { await loadMore() } }
                        .frame(minHeight: Tokens.minHitSize)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, Tokens.Spacing.xl)
                .accessibilityIdentifier("songs-more-error")
            } else if loadingMore {
                ProgressView().padding(.vertical, Tokens.Spacing.xl)
            }
        }
        .padding(.vertical, Tokens.Spacing.s)
        .foregroundStyle(p.inkColor)
    }

    private func loadFirst() async {
        do {
            let first = try await model.songsPage(0)
            nextPage = 1
            exhausted = first.isEmpty
            moreError = nil
            songs = .loaded(first)
        } catch {
            songs = .failed(BrowseErrorCopy.message(for: error))
        }
    }

    /// The next page. A page can come back short when the server leaves out missing files, so only an empty page ends
    /// the list.
    private func loadMore() async {
        guard !exhausted, !loadingMore, let current = songs.value else { return }
        loadingMore = true
        moreError = nil
        defer { loadingMore = false }
        let more: [Song]
        do {
            more = try await model.songsPage(nextPage)
        } catch {
            moreError = BrowseErrorCopy.message(for: error)
            return
        }
        nextPage += 1
        exhausted = more.isEmpty
        let known = Set(current.map(\.id))
        songs = .loaded(current + more.filter { !known.contains($0.id) })
    }
}
