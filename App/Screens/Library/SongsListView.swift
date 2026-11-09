import DesignSystem
import MagpieCore
import SwiftUI

/// Library › Songs (spec §3, Task 21): every song, A–Z by title, `AppModel.songsPageSize` at a time; the next page is
/// read when the last row appears. A row plays the songs read so far, from that song. The letter index (P2) jumps to a
/// letter's first song (`PagedLetterList`). Round 24 (owner, 2026-11-08): a "Search songs" field at the top (D224), and
/// a header per loaded letter run past 25 songs (D225).
struct SongsListView: View {
    @Environment(AppModel.self) private var model
    @State private var list: PagedLetterList<Song>?
    @State private var removing: Song?
    /// The running letter jump (its seek reads the server), cancelled when the screen goes.
    @State private var jumpTask: Task<Void, Never>?
    /// Round 24 (D224): the list's own search, songs only.
    @State private var search: SearchModel?

    private var searching: Bool { search.map(KindSearch.showsResults) ?? false }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if let list {
                    LoadableView(state: list.items, retry: { await list.load() }) { songs in
                        if songs.isEmpty {
                            ContentUnavailableView("No songs yet", systemImage: "music.note",
                                                   description: Text("Songs show up here once your server has some."))
                        } else {
                            SongLetterRows(songs: songs, list: list, removing: $removing)
                        }
                    }
                }
            }
            .letterIndex(available: list?.availableLetters ?? [],
                         hidden: list?.items.value?.isEmpty != false || searching) { letter in
                pick(letter)
            }
            .overlay { if list?.seeking == true { ProgressView().accessibilityLabel("Finding songs") } }
            .onChange(of: list?.scrollRequest) { _, request in
                if let request { proxy.scrollTo(request.id, anchor: .top) }
            }
        }
        .kindSearch(.songs, search)   // round 24 (D224): "Search songs" at the top
        .navigationTitle("Songs")
        .navigationBarTitleDisplayMode(.inline)
        .magpieScreen()
        .songRemovalDialog($removing)
        .onDisappear { jumpTask?.cancel() }
        .task {
            if search == nil { search = model.kindSearchModel(.songs) }
            if list == nil {
                let model = model
                list = PagedLetterList(pageSize: AppModel.songsPageSize, name: \.title, id: \.id,
                                       read: { try await model.songsWindow(from: $0) },
                                       seek: { try await model.songOffset(forLetter: $0) })
            }
            if list?.items.value == nil { await list?.load() }
        }
    }

    /// A letter picked while a jump runs joins it (the latest wins); otherwise a new jump, kept so leaving cancels it.
    private func pick(_ letter: String) {
        guard let list else { return }
        if let task = list.startJump(to: letter) { jumpTask = task }   // nil: it joined the running jump
    }
}

/// The songs read so far, in a `LazyVStack` whose letter headers pin at the top (D225: more than 25 songs and the A–Z
/// bar on screen; only the loaded runs, so a header never claims songs not read yet).
private struct SongLetterRows: View {
    @Environment(AppModel.self) private var model
    let songs: [Song]
    let list: PagedLetterList<Song>
    @Binding var removing: Song?
    @Environment(\.letterIndexShown) private var barShown
    private let themed = Themed()

    var body: some View {
        let p = themed.palette
        let runs = LetterSectionHeader.runs(list.sections, itemCount: songs.count, barShown: barShown)
        return LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
            if list.windowStart > 0 {
                Button(list.loadingEarlier ? "Loading…" : "Show earlier songs") { Task { await list.loadEarlier() } }
                    .frame(maxWidth: .infinity, minHeight: Tokens.minHitSize)
                    .tint(p.accentInkColor)
                    .accessibilityIdentifier("songs-earlier")
            }
            if runs.isEmpty {
                rows(songs.indices)
            } else {
                ForEach(runs, id: \.range.lowerBound) { run in
                    Section { rows(run.range) } header: { LetterSectionHeader(key: run.key, pinned: true) }
                }
            }
            if let moreError = list.moreError {
                VStack(spacing: Tokens.Spacing.s) {
                    Text(moreError).font(.footnote).multilineTextAlignment(.center)
                    Button("Try again") { Task { await list.loadMore() } }
                        .frame(minHeight: Tokens.minHitSize)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, Tokens.Spacing.xl)
                .accessibilityIdentifier("songs-more-error")
            } else if list.loadingMore {
                ProgressView().padding(.vertical, Tokens.Spacing.xl)
            }
        }
        .padding(.vertical, Tokens.Spacing.s)
        .foregroundStyle(p.inkColor)
    }

    /// The rows at `indices` (their index in the songs read so far: what plays, and the UI tests' "song-N").
    private func rows(_ indices: Range<Int>) -> some View {
        let p = themed.palette
        return ForEach(Array(zip(indices, songs[indices])), id: \.1.id) { index, song in
            Button { model.play(songs, startAt: index) } label: {
                Artwork(song.coverArtId, side: 48) { image in
                    SongRow(song: song, state: .library, artwork: image)
                }
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("song-\(index)")
            .contextMenu { SongQueueMenuItems(song: song); SongDownloadMenuItem(song: song, removing: $removing) }
            .songSwipeActions(song, in: .stack)   // R12
            .onAppear { if index == songs.count - 1 { Task { await list.loadMore() } } }
            .id(song.id)
            Divider().overlay(p.sepColor).padding(.leading, 76)
        }
    }
}
