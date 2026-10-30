import DesignSystem
import MagpieCore
import SwiftUI

/// Library › Songs (spec §3, Task 21): every song, A–Z by title, `AppModel.songsPageSize` at a time; the next page is
/// read when the last row appears. A row plays the songs read so far, from that song. The letter index (P2) jumps to a
/// letter's first song (`PagedLetterList`).
struct SongsListView: View {
    @Environment(AppModel.self) private var model
    @State private var list: PagedLetterList<Song>?
    @State private var removing: Song?
    /// The running letter jump (its seek reads the server), cancelled when the screen goes.
    @State private var jumpTask: Task<Void, Never>?
    private let themed = Themed()

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if let list {
                    LoadableView(state: list.items, retry: { await list.load() }) { songs in
                        if songs.isEmpty {
                            ContentUnavailableView("No songs yet", systemImage: "music.note",
                                                   description: Text("Songs show up here once your server has some."))
                        } else {
                            rows(songs, list)
                        }
                    }
                }
            }
            .letterIndex(available: list?.availableLetters ?? [], hidden: list?.items.value?.isEmpty != false) { letter in
                pick(letter)
            }
            .overlay { if list?.seeking == true { ProgressView().accessibilityLabel("Finding songs") } }
            .onChange(of: list?.scrollRequest) { _, request in
                if let request { proxy.scrollTo(request.id, anchor: .top) }
            }
        }
        .navigationTitle("Songs")
        .navigationBarTitleDisplayMode(.inline)
        .magpieScreen()
        .songRemovalDialog($removing)
        .onDisappear { jumpTask?.cancel() }
        .task {
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

    private func rows(_ songs: [Song], _ list: PagedLetterList<Song>) -> some View {
        let p = themed.palette
        return LazyVStack(spacing: 0) {
            if list.windowStart > 0 {
                Button(list.loadingEarlier ? "Loading…" : "Show earlier songs") { Task { await list.loadEarlier() } }
                    .frame(maxWidth: .infinity, minHeight: Tokens.minHitSize)
                    .tint(p.accentInkColor)
                    .accessibilityIdentifier("songs-earlier")
            }
            ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                Button { model.play(songs, startAt: index) } label: {
                    Artwork(song.coverArtId, side: 48) { image in
                        SongRow(song: song, state: .library, artwork: image)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("song-\(index)")
                .contextMenu { SongDownloadMenuItem(song: song, removing: $removing) }
                .onAppear { if index == songs.count - 1 { Task { await list.loadMore() } } }
                .id(song.id)
                Divider().overlay(p.sepColor).padding(.leading, 76)
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
}
