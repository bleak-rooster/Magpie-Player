import DesignSystem
import MagpieCore
import Search
import SwiftUI

/// A "Made for you" playlist (Task 7.1c): its songs in order. Library songs play (Play / Shuffle take only those);
/// songs not in the library are record rows with "Not in your library" and Try (D3).
struct MadeForYouView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.magpieTheme) private var theme
    let playlist: MadeForYou.Playlist
    @State private var rows: Loadable<[MadeForYouRow]> = .loading
    @State private var trying: TryTarget?
    private let themed = Themed()

    static let unavailable = "This playlist can't be opened right now. Try again in a moment."

    var body: some View {
        ScrollView {
            LoadableView(state: rows, retry: load) { rows in
                content(rows)
            }
        }
        .navigationTitle(playlist.title)
        .navigationBarTitleDisplayMode(.inline)
        .magpieScreen()
        .sheet(item: $trying) { TrySheet(recording: $0.recording) }
        .task { if rows.value == nil { await load() } }
    }

    private func content(_ rows: [MadeForYouRow]) -> some View {
        let p = themed.palette
        let songs = rows.compactMap { if case .library(let song) = $0 { song } else { nil } }
        let notYet = rows.count - songs.count
        return VStack(spacing: Tokens.Spacing.l) {
            VStack(spacing: Tokens.Spacing.s) {
                Text(playlist.title).magpieDisplay(.title).multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Text(summary(inLibrary: songs.count, notYet: notYet))
                    .font(theme.numberFont(.footnote)).foregroundStyle(p.ink2Color)
            }
            .padding(.horizontal, Tokens.Spacing.largeTitleMargin)

            PlayShuffleButtons(songs: songs)

            LazyVStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    self.row(row, index: index, songs: songs)
                    Divider().overlay(p.sepColor).padding(.leading, 76)
                }
            }
        }
        .padding(.vertical, Tokens.Spacing.l)
        .foregroundStyle(p.inkColor)
    }

    @ViewBuilder private func row(_ row: MadeForYouRow, index: Int, songs: [Song]) -> some View {
        switch row {
        case .library(let song):
            Button { model.play(songs, startAt: songs.firstIndex(of: song) ?? 0) } label: {
                Artwork(song.coverArtId, side: 48) { image in
                    SongRow(song: song, state: .library, artwork: image)
                }
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("made-for-you-track-\(index)")
        case .notYet(let recording):
            SongRow(song: Song(id: "notyet-\(index)", title: recording.title, artist: recording.artist,
                               album: recording.releaseTitle ?? "", duration: recording.duration ?? 0),
                    state: RequestCopy.rowState(for: recording, in: model.requests),
                    onTry: { trying = TryTarget(recording: recording) })
                .accessibilityIdentifier("made-for-you-notyet-\(index)")
        }
    }

    private func summary(inLibrary: Int, notYet: Int) -> String {
        let library = inLibrary == 1 ? "1 song in your library" : "\(inLibrary) songs in your library"
        return notYet == 0 ? library : "\(library) · \(notYet) not in your library"
    }

    private func load() async {
        if let found = await model.madeForYouTracks(playlist.id) {
            rows = .loaded(found)
        } else if rows.value == nil {
            rows = .failed(Self.unavailable)
        }
    }
}
