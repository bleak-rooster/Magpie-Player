import DesignSystem
import MagpieCore
import Playback
import SwiftUI

/// Now Playing sheet: art (or lyrics in its place), title, artist, star, scrubber (rounded numerals, hallmark),
/// transport, Up next, and Lyrics / Sleep timer / Queue. Signature has a "Playing from" top bar; Classic a close button.
/// At standard text sizes it fits one screen and never scrolls: the art takes the height the rest leaves (D43).
/// At accessibility sizes the page scrolls, text wraps instead of truncating, and the times sit above the hallmark (D15).
struct NowPlayingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.magpieTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var scrubbing: TimeInterval?
    @State private var showsQueue = false
    /// Lyrics in the art's place; stays on across songs.
    @State private var showsLyrics = false
    /// The server advertises `songLyrics` (A13); the Lyrics button is hidden until it does.
    @State private var lyricsAvailable = false
    /// Measured heights of everything but the art and Up next (D43).
    @State private var partHeights: [String: CGFloat] = [:]
    /// Up next's last measured height, kept while it is hidden so the plan doesn't flip back and forth.
    /// Seeded with the default-size row (36 pt art + 2 × 8 pt padding) so a small phone doesn't flash it on the first frame.
    @State private var upNextHeight: CGFloat = 52
    private let themed = Themed()

    var body: some View {
        let player = model.player
        Group {
            if let song = player.queue.current?.song {
                GeometryReader { geo in
                    let width = geo.size.width - 2 * Tokens.Spacing.xxl
                    if typeSize.isAccessibilitySize {
                        let side = NowPlayingLayout.artSide(available: CGSize(width: width, height: geo.size.height), reserved: 0)
                        ScrollView {
                            stack(song, player, side: side, spacing: Tokens.Spacing.xl, showsUpNext: true)
                        }
                    } else {
                        let shown = partHeights.filter { key, _ in
                            (key != "hint" || model.playbackHint != nil) && (key != "error" || player.lastError != nil)
                        }
                        let parts = shown.values.reduce(2 * Tokens.Spacing.l, +)   // vertical padding included
                        let next = player.queue.nextUp?.song
                        let plan = NowPlayingLayout.plan(available: CGSize(width: width, height: geo.size.height),
                                                         parts: parts, gaps: shown.count,
                                                         upNext: next == nil ? nil : upNextHeight)
                        // Hidden until the always-present parts have measured, so the first frame isn't oversized art.
                        let measured = ["top", "meta", "scrubber", "transport", "bottom"].allSatisfy { partHeights[$0] != nil }
                        stack(song, player, side: plan.side, spacing: plan.spacing, showsUpNext: plan.showsUpNext)
                            .opacity(measured ? 1 : 0)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("now-playing")
            } else {
                ContentUnavailableView("Nothing playing", systemImage: "music.note")
            }
        }
        .foregroundStyle(themed.palette.inkColor)
        .background { ArtBackdrop(coverArtId: model.player.queue.current?.song.coverArtId) }
        .presentationDragIndicator(theme.character == .classic ? .visible : .hidden)
        .task { lyricsAvailable = (try? await model.serverAdvertises("songLyrics")) ?? false }
        .sheet(isPresented: $showsQueue) { QueueView() }
    }

    /// The top bar, then the art and the rest. Spare height (art capped at 360) goes under the top bar.
    private func stack(_ song: Song, _ player: Player, side: CGFloat, spacing: CGFloat, showsUpNext: Bool) -> some View {
        let p = themed.palette
        return VStack(spacing: 0) {
            Group {
                if theme.character != .classic {
                    topBar(song)
                } else {
                    // The grabber alone can't be reached by VoiceOver or Switch Control (H3 M11).
                    HStack { closeButton; Spacer() }
                }
            }
            .nowPlayingPart("top", into: $partHeights)
            .padding(.bottom, spacing)
            Spacer(minLength: 0)
            VStack(spacing: spacing) {
                artSlot(song, player, side: side)
                meta(song).nowPlayingPart("meta", into: $partHeights)
                scrubber(song, player).nowPlayingPart("scrubber", into: $partHeights)
                if let hint = model.playbackHint {
                    HStack(alignment: .firstTextBaseline) {
                        Label(hint, systemImage: "info.circle")
                            .font(.footnote).foregroundStyle(p.ink2Color)
                        Spacer(minLength: Tokens.Spacing.s)
                        Button { model.dismissPlaybackHint() } label: { Image(systemName: "xmark") }
                            .accessibilityLabel("Dismiss")
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .nowPlayingPart("hint", into: $partHeights)
                }
                if let error = player.lastError {
                    Label("This song didn't play. Try it again, or skip to the next one.",
                          systemImage: "exclamationmark.triangle")
                        .font(.footnote).foregroundStyle(p.ink2Color)
                        .accessibilityHint(error)
                        .nowPlayingPart("error", into: $partHeights)
                }
                transport(player).nowPlayingPart("transport", into: $partHeights)
                if showsUpNext, let next = player.queue.nextUp?.song {
                    upNext(next)
                        .fixedSize(horizontal: false, vertical: true)
                        .nowPlayingHeight("upNext", into: $upNextHeight)
                        .nowPlayingProbe("upNext")
                }
                bottomBar.nowPlayingPart("bottom", into: $partHeights)
            }
        }
        .padding(.horizontal, Tokens.Spacing.xxl)
        .padding(.vertical, Tokens.Spacing.l)
    }

    /// The art, or the lyrics in its place at the same size (D43). A cross-fade, none under Reduce Motion (D15).
    private func artSlot(_ song: Song, _ player: Player, side: CGFloat) -> some View {
        ZStack {
            if showsLyrics && lyricsAvailable {
                LyricsContent { setLyrics(false) }
                    .transition(.opacity)
            } else {
                Artwork(song.coverArtId, side: 340) { image in
                    SleeveArt(image: image, side: nil)
                        .aspectRatio(1, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.hero, style: .continuous))
                }
                .shadow(color: .black.opacity(0.22), radius: 24, y: 12)
                .scaleEffect(player.isPlaying ? 1 : 0.92)
                .animation(.spring(duration: 0.4), value: player.isPlaying)
                .transition(.opacity)
            }
        }
        .frame(width: side, height: side)
        .nowPlayingProbe("art")
    }

    private func setLyrics(_ on: Bool) {
        if reduceMotion { showsLyrics = on }
        else { withAnimation(.easeInOut(duration: 0.25)) { showsLyrics = on } }
    }

    private func topBar(_ song: Song) -> some View {
        HStack {
            closeButton
            Spacer()
            VStack(spacing: 1) {
                Text("Playing from").font(.caption).foregroundStyle(themed.palette.ink2Color)
                Text(song.album).font(.footnote.weight(.semibold)).lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            Spacer()
            Color.clear.frame(width: Tokens.minHitSize, height: Tokens.minHitSize)   // balances the close button
        }
        .buttonStyle(.plain)
    }

    private var closeButton: some View {
        Button { dismiss() } label: {
            Image(systemName: "chevron.down").font(.title3.weight(.semibold))
                .frame(width: Tokens.minHitSize, height: Tokens.minHitSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close Now Playing")
    }

    private func meta(_ song: Song) -> some View {
        let starred = model.isStarred(song)
        let ax = typeSize.isAccessibilitySize
        // The star goes below at accessibility sizes, so a long artist name gets the full width.
        let layout = ax ? AnyLayout(VStackLayout(alignment: .leading, spacing: Tokens.Spacing.s))
                        : AnyLayout(HStackLayout(alignment: .center, spacing: Tokens.Spacing.m))
        return layout {
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title).magpieDisplay(.title2).lineLimit(ax ? nil : 2)
                    .accessibilityIdentifier("np-title")
                Text(song.artist).font(.title3).foregroundStyle(themed.palette.ink2Color).lineLimit(ax ? nil : 1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            Button { Task { await model.toggleStar(song) } } label: {
                Image(systemName: starred ? "star.fill" : "star")
                    .font(.title3)
                    .foregroundStyle(starred ? themed.palette.accentInkColor : themed.palette.inkColor)
                    .frame(width: Tokens.minHitSize, height: Tokens.minHitSize)
                    .background(themed.palette.solidSurfaceColor, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Star")
            .accessibilityAddTraits(starred ? .isSelected : [])
            .sensoryFeedback(.selection, trigger: starred)
        }
    }

    private func scrubber(_ song: Song, _ player: Player) -> some View {
        let duration = max(player.duration ?? song.duration, 1)
        let elapsed = min(scrubbing ?? player.position, duration)
        return VStack(spacing: Tokens.Spacing.xs) {
            Slider(value: Binding(get: { elapsed }, set: { scrubbing = $0 }), in: 0...duration) { editing in
                if !editing, let t = scrubbing {
                    player.seek(t)
                    scrubbing = nil
                }
            }
            .accessibilityLabel("Playback position")
            .accessibilityValue("\(DurationText.spoken(elapsed)) of \(DurationText.spoken(duration))")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: player.seek(min(duration, player.position + 15))
                case .decrement: player.seek(max(0, player.position - 15))
                @unknown default: break
                }
            }
            let elapsedText = Text(DurationText.clock(elapsed)).accessibilityHidden(true)   // the slider speaks the time
            let remainingText = Text("-" + DurationText.clock(duration - elapsed)).accessibilityHidden(true)
            Group {
                if typeSize.isAccessibilitySize {
                    // Times on their own line, the hallmark below with the full width, so it never hyphenates.
                    VStack(spacing: Tokens.Spacing.xs) {
                        HStack { elapsedText; Spacer(); remainingText }
                        Hallmark(model.quality(of: song))
                    }
                } else {
                    HStack {
                        elapsedText
                        Spacer()
                        Hallmark(model.quality(of: song))   // "Lossless soon" for a kept find (Task 6.2b)
                        Spacer()
                        remainingText
                    }
                }
            }
            .font(theme.numberFont(.caption))
            .foregroundStyle(themed.palette.ink2Color)
        }
    }

    private func transport(_ player: Player) -> some View {
        HStack(spacing: 44) {
            Button { player.previous() } label: {
                Image(systemName: "backward.fill").font(.title)
                    .frame(width: 60, height: 60)
            }
            .accessibilityLabel("Previous")
            Button { player.toggle() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 34))
                    .frame(width: 76, height: 76)
                    .background(themed.palette.solidSurfaceColor, in: Circle())
            }
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            .accessibilityIdentifier("np-play-pause")
            Button { player.next() } label: {
                Image(systemName: "forward.fill").font(.title)
                    .frame(width: 60, height: 60)
            }
            .accessibilityLabel("Next")
        }
        .buttonStyle(.plain)
    }

    private func upNext(_ song: Song) -> some View {
        let ax = typeSize.isAccessibilitySize
        let label = ax ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
                       : AnyLayout(HStackLayout(spacing: Tokens.Spacing.m))
        return Button { showsQueue = true } label: {
            HStack(spacing: Tokens.Spacing.m) {
                if !ax { Artwork(song.coverArtId, side: 36) { SleeveArt(image: $0, side: 36) } }
                label {
                    Text("Up next").font(.footnote.weight(.semibold)).foregroundStyle(themed.palette.ink2Color)
                    Text(song.title).font(.footnote).lineLimit(ax ? nil : 1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.footnote).foregroundStyle(themed.palette.ink2Color)
            }
            .padding(Tokens.Spacing.s)
            .background(themed.palette.solidSurfaceColor, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Up next: \(song.title), \(song.artist)")
        .accessibilityHint("Opens the queue")
        .accessibilityAddTraits(.isButton)
    }

    /// Lyrics | Sleep timer | Queue, evenly spaced. The moon stays centred while Lyrics is hidden.
    private var bottomBar: some View {
        HStack {
            if lyricsAvailable {
                Button { setLyrics(!showsLyrics) } label: {
                    Image(systemName: showsLyrics ? "quote.bubble.fill" : "quote.bubble")
                        .font(.title3).frame(width: Tokens.minHitSize, height: Tokens.minHitSize)
                }
                .accessibilityLabel("Lyrics")
                .accessibilityAddTraits(showsLyrics ? .isSelected : [])
            } else {
                Color.clear.frame(width: Tokens.minHitSize, height: Tokens.minHitSize).accessibilityHidden(true)
            }
            Spacer()
            SleepTimerMenu()
            Spacer()
            Button { showsQueue = true } label: {
                Image(systemName: "list.bullet").font(.title3).frame(width: Tokens.minHitSize, height: Tokens.minHitSize)
            }
            .accessibilityLabel("Queue")
        }
        .buttonStyle(.plain)
        .foregroundStyle(themed.palette.ink2Color)
    }
}
