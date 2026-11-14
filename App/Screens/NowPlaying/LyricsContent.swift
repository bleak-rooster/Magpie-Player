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

/// Loads one song's lyrics at a time. Skipping cancels the previous load: a cancelled or stale answer (failure
/// included) never overwrites the new song's state, so a quick run of skips doesn't flash an error.
/// Round 27 L (owner, 2026-11-14): generic so the pane can load `ShownLyrics` (lines or the instrumental note, with
/// where they came from, D313); `LyricsLoader` stays the plain-lyrics one.
@MainActor @Observable final class LyricsLoaderOf<Value: Sendable> {
    private(set) var state: Loadable<Value?> = .loading
    /// The last few states written, oldest first (tests read it to prove no stale failure landed).
    private(set) var history: [Loadable<Value?>] = []

    /// `current` is the song now playing, checked again when the answer arrives.
    func load(_ id: String?, current: () -> String?, fetch: (String) async throws -> Value?) async {
        guard let id else { set(.loaded(nil)); return }
        set(.loading)
        let result: Loadable<Value?>
        do {
            result = .loaded(try await fetch(id))
        } catch is CancellationError {
            return
        } catch {
            result = .failed(BrowseErrorCopy.message(for: error))
        }
        guard !Task.isCancelled, current() == id else { return }
        set(result)
    }

    private func set(_ new: Loadable<Value?>) {
        state = new
        history = Array((history + [new]).suffix(16))
    }
}

typealias LyricsLoader = LyricsLoaderOf<Lyrics>

/// The current song's lyrics, in place of the art on Now Playing (D43) and sized like it: long lyrics scroll
/// inside this slot only. Synced lyrics follow the playback position (the sung line is full-strength, the rest
/// dimmed; tap a line to jump there); unsynced lyrics are plain text. A new song loads its own lyrics.
/// Only offered when the server advertises `songLyrics` (A13) or Find lyrics online is on.
/// Round 27 L (owner, 2026-11-14): the answer the background ask kept is shown at once, without a read (D310); with
/// Find lyrics online on, LRCLIB fills in when the library has none (D311); the footer says where the lyrics came from,
/// and what's shown for a song stays while the pane is open (D313). Pull down, or Try again, to read afresh.
struct LyricsContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var loader = LyricsLoaderOf<ShownLyrics>()
    /// Brings the art back.
    let onClose: () -> Void
    private let themed = Themed()

    var body: some View {
        let song = model.player.queue.current?.song
        let shape = RoundedRectangle(cornerRadius: Tokens.Radius.hero, style: .continuous)
        ScrollViewReader { proxy in
            ScrollView {
                LoadableView(state: loader.state, retry: { await load(song, fresh: true) }) { shown in
                    switch shown {
                    case .lines(let lyrics, let source)? where !lyrics.lines.isEmpty:
                        content(lyrics, footer: ShownLyrics.lines(lyrics, source).footer, proxy: proxy)
                    case .instrumental(let source)?:
                        instrumental(footer: ShownLyrics.instrumental(source).footer)
                    default:
                        ContentUnavailableView {
                            Label(Self.emptyTitle(offline: model.isOffline), systemImage: Self.emptySymbol(offline: model.isOffline))
                        } actions: {
                            if !model.isOffline {
                                Button("Try again") { Task { await load(song, fresh: true) } }
                                    .frame(minHeight: Tokens.minHitSize)
                                    .accessibilityIdentifier("lyrics-try-again")
                            }
                        }
                        .accessibilityIdentifier("lyrics-empty")
                    }
                }
            }
            .refreshable { await load(song, fresh: true) }
        }
        .background(themed.palette.solidSurfaceColor, in: shape)
        .clipShape(shape)
        .overlay(alignment: .topTrailing) {
            Button(action: onClose) {
                Image(systemName: "xmark").font(.footnote.weight(.semibold))
                    .frame(width: 30, height: 30)
                    .background(themed.palette.solidSurfaceColor, in: Circle())
                    .frame(width: Tokens.minHitSize, height: Tokens.minHitSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Hide lyrics")
            .accessibilityIdentifier("lyrics-close")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("np-lyrics")
        .task(id: song?.id) { await load(song) }
    }

    private func content(_ lyrics: Lyrics, footer: String, proxy: ScrollViewProxy) -> some View {
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
            Text(footer).font(.footnote).foregroundStyle(p.ink2Color)
                .padding(.top, Tokens.Spacing.l)
                .accessibilityIdentifier("lyrics-source")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Tokens.Spacing.l)
        .padding(.trailing, Tokens.Spacing.l)   // clear of the close button
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

    /// L fix round 1 (M1): with nothing kept and Magpie offline, the pane says it's offline rather than that the song
    /// has no lyrics.
    static func emptyTitle(offline: Bool) -> String { offline ? AppModel.offlineCopy : "No lyrics for this song" }
    static func emptySymbol(offline: Bool) -> String { offline ? "wifi.slash" : "quote.bubble" }

    /// Round 27 L (D311): the instrumental note, with where it came from.
    private func instrumental(footer: String) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.l) {
            Label(ShownLyrics.instrumentalNote, systemImage: "music.note")
                .font(.title3.weight(.semibold))
                .accessibilityIdentifier("lyrics-instrumental")
            Text(footer).font(.footnote).foregroundStyle(themed.palette.ink2Color)
                .accessibilityIdentifier("lyrics-source")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Tokens.Spacing.l)
        .padding(.trailing, Tokens.Spacing.l)
        .foregroundStyle(themed.palette.inkColor)
    }

    private func load(_ song: Song?, fresh: Bool = false) async {
        await loader.load(song?.id, current: { model.player.queue.current?.song.id }) { _ in
            guard let song else { return nil }
            return try await model.lyricsForPane(song, fresh: fresh)
        }
    }
}
