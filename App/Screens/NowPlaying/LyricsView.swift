import DesignSystem
import MagpieCore
import Playback
import SwiftUI

/// Which lyric line is being sung at `position`: the last line that has started. Nil before the
/// first line, and for unsynced lyrics.
enum LyricsTimeline {
    static func activeIndex(in lyrics: Lyrics, at position: TimeInterval) -> Int? {
        guard lyrics.synced else { return nil }
        var active: Int?
        for (i, line) in lyrics.lines.enumerated() {
            guard let start = line.start else { continue }
            if start <= position { active = i } else { break }
        }
        return active
    }
}

/// The current song's lyrics. Synced lyrics follow the playback position (the sung line is
/// full-strength, the rest dimmed; tap a line to jump there); unsynced lyrics are plain text.
/// Only offered when the server advertises `songLyrics` (A13).
struct LyricsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lyrics: Loadable<Lyrics?> = .loading
    private let themed = Themed()

    var body: some View {
        let song = model.player.queue.current?.song
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LoadableView(state: lyrics, retry: { await load(song) }) { lyrics in
                        if let lyrics, !lyrics.lines.isEmpty {
                            content(lyrics, proxy: proxy)
                        } else {
                            ContentUnavailableView("No lyrics for this song", systemImage: "quote.bubble")
                                .accessibilityIdentifier("lyrics-empty")
                        }
                    }
                }
            }
            .navigationTitle(song?.title ?? "Lyrics")
            .navigationBarTitleDisplayMode(.inline)
            .magpieScreen()
        }
        .presentationDetents([.medium, .large])
        .task(id: song?.id) { await load(song) }
    }

    private func content(_ lyrics: Lyrics, proxy: ScrollViewProxy) -> some View {
        let p = themed.palette
        let player = model.player
        let active = LyricsTimeline.activeIndex(in: lyrics, at: player.position)
        return VStack(alignment: .leading, spacing: Tokens.Spacing.l) {
            ForEach(Array(lyrics.lines.enumerated()), id: \.offset) { index, line in
                let isActive = index == active
                Group {
                    if lyrics.synced, let start = line.start {
                        Button { player.seek(start) } label: { lineText(line.text, active: isActive) }
                            .buttonStyle(.plain)
                            .accessibilityHint("Jumps to this line")
                    } else {
                        lineText(line.text, active: true)
                    }
                }
                .id(index)
                .accessibilityAddTraits(isActive ? .isSelected : [])
            }
            Text("Lyrics from your library").font(.footnote).foregroundStyle(p.ink2Color)
                .padding(.top, Tokens.Spacing.l)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Tokens.Spacing.xxl)
        .foregroundStyle(p.inkColor)
        .onChange(of: active) { _, new in
            guard let new else { return }
            if reduceMotion { proxy.scrollTo(new, anchor: .center) }
            else { withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(new, anchor: .center) } }
        }
    }

    private func lineText(_ text: String, active: Bool) -> some View {
        Text(text.isEmpty ? "\u{266A}" : text)
            .font(.title3.weight(.semibold))
            .opacity(active ? 1 : 0.45)
            .frame(maxWidth: .infinity, minHeight: Tokens.minHitSize / 2, alignment: .leading)
            .multilineTextAlignment(.leading)
    }

    private func load(_ song: Song?) async {
        guard let id = song?.id else { lyrics = .loaded(nil); return }
        lyrics = .loading
        do {
            lyrics = .loaded(try await model.request { try await $0.lyrics(songId: id) })
        } catch {
            lyrics = .failed(BrowseErrorCopy.message(for: error))
        }
    }
}
