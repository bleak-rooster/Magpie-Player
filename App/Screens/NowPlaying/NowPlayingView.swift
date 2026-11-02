import DesignSystem
import MagpieCore
import Playback
import SwiftUI

/// Now Playing sheet: art (or lyrics in its place), title, artist, star, scrubber (rounded numerals, hallmark),
/// transport, Up next, and Lyrics / Sleep timer / Queue. Signature has a "Playing from" top bar; Classic a close button.
/// At standard text sizes it fits one screen and never scrolls: the art takes the height the rest leaves (D43).
/// Lyrics mode (P6) gives the lyrics everything between the top bar and a compact title line above the scrubber; Up
/// next and the playback hint step aside, the transport and bottom row stay, and only the lyrics scroll.
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
    /// Where the album and artist names go (R10); recomputed per song and when offline mode changes.
    @State private var links = NowPlayingLinks()
    /// The current tab's stack, which the links push onto (absent in tests: the links do nothing).
    @Environment(TabNavigator.self) private var navigator: TabNavigator?
    private let themed = Themed()

    /// `showingLyrics` opens in lyrics mode, as if the server offered them (tests).
    init(showingLyrics: Bool = false) {
        _showsLyrics = State(initialValue: showingLyrics)
        _lyricsAvailable = State(initialValue: showingLyrics)
    }

    /// Lyrics in the art's place, laid out to fill the page (P6).
    private var lyricsMode: Bool { showsLyrics && lyricsAvailable }

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
                        // One branch for art and lyrics mode, so the toggle cross-fades the slot, not the page (P6).
                        let page = pagePlan(player, available: CGSize(width: width, height: geo.size.height))
                        stack(song, player, side: page.side, lyricsHeight: page.lyricsHeight, spacing: page.spacing,
                              showsUpNext: page.showsUpNext)
                            .opacity(page.measured ? 1 : 0)
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
        .task { if !lyricsAvailable { lyricsAvailable = (try? await model.serverAdvertises("songLyrics")) ?? false } }
        .sheet(isPresented: $showsQueue) { QueueView() }
        .task(id: "\(model.player.queue.current?.song.id ?? "")|\(model.offlinePageKey)") { await resolveLinks() }
    }

    private func resolveLinks() async {
        guard let song = model.player.queue.current?.song else { return }
        links = await model.nowPlayingLinks(song)
    }

    /// R10: Now Playing goes away and the page pushes onto the tab the user is on.
    private func open(_ route: Route) {
        dismiss()
        navigator?.push(route)
    }

    private struct PagePlan {
        var side: CGFloat
        var lyricsHeight: CGFloat?
        var spacing: CGFloat
        var showsUpNext: Bool
        /// The always-present parts have measured; until then the page is hidden, so the first frame isn't oversized.
        var measured: Bool
    }

    /// The default-size page: the art takes what the rest leaves (D43); in lyrics mode the lyrics do, full width (P6).
    private func pagePlan(_ player: Player, available: CGSize) -> PagePlan {
        if lyricsMode {
            let shown = lyricsParts(player)
            let parts = shown.values.reduce(2 * Tokens.Spacing.l, +)   // vertical padding included
            let height = NowPlayingLayout.lyricsHeight(available: available, parts: parts, gaps: shown.count)
            let measured = ["top", "scrubber", "transport", "bottom"].allSatisfy { partHeights[$0] != nil }
            return PagePlan(side: available.width, lyricsHeight: height, spacing: NowPlayingLayout.lyricsSpacing,
                            showsUpNext: false, measured: measured)
        }
        let shown = partHeights.filter { key, _ in
            key != "metaCompact"
                && (key != "hint" || model.playbackHint != nil) && (key != "error" || player.lastError != nil)
        }
        let parts = shown.values.reduce(2 * Tokens.Spacing.l, +)   // vertical padding included
        let next = player.queue.nextUp?.song
        let plan = NowPlayingLayout.plan(available: available, parts: parts, gaps: shown.count,
                                         upNext: next == nil ? nil : upNextHeight)
        let measured = ["top", "meta", "scrubber", "transport", "bottom"].allSatisfy { partHeights[$0] != nil }
        return PagePlan(side: plan.side, lyricsHeight: nil, spacing: plan.spacing, showsUpNext: plan.showsUpNext,
                        measured: measured)
    }

    /// Lyrics mode's measured parts (P6). The compact line stands in for the title; until it has measured, the full
    /// title's height stands in for it (taller, so the first frame never overflows).
    private func lyricsParts(_ player: Player) -> [String: CGFloat] {
        var shown = partHeights.filter { key, _ in
            ["top", "scrubber", "transport", "bottom"].contains(key) || (key == "error" && player.lastError != nil)
        }
        shown["metaCompact"] = partHeights["metaCompact"] ?? partHeights["meta"]
        return shown
    }

    /// The top bar, then the art and the rest. Spare height (art capped at 360) goes under the top bar.
    /// With `lyricsHeight` (lyrics mode, P6), the lyrics are `side` wide and that tall, the compact title line stands
    /// in for the title, and the hint stays out.
    private func stack(_ song: Song, _ player: Player, side: CGFloat, lyricsHeight: CGFloat? = nil, spacing: CGFloat,
                       showsUpNext: Bool) -> some View {
        let p = themed.palette
        return VStack(spacing: 0) {
            Group {
                if theme.character != .classic {
                    topBar(song)
                } else {
                    // The grabber alone can't be reached by VoiceOver or Switch Control (H3 M11).
                    HStack { closeButton; Spacer(); moreMenu(song) }
                }
            }
            .nowPlayingPart("top", into: $partHeights)
            .padding(.bottom, spacing)
            Spacer(minLength: 0)
            VStack(spacing: spacing) {
                artSlot(song, player, side: side, lyricsHeight: lyricsHeight)
                if lyricsHeight != nil {
                    compactMeta(song).nowPlayingPart("metaCompact", into: $partHeights)
                } else {
                    meta(song).nowPlayingPart("meta", into: $partHeights)
                }
                scrubber(song, player).nowPlayingPart("scrubber", into: $partHeights)
                if lyricsHeight == nil, let hint = model.playbackHint {
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

    /// The art, or the lyrics in its place: at the art's size where the page scrolls (accessibility sizes), otherwise
    /// `side` wide and `lyricsHeight` tall (P6). A cross-fade, none under Reduce Motion (D15).
    private func artSlot(_ song: Song, _ player: Player, side: CGFloat, lyricsHeight: CGFloat? = nil) -> some View {
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
        .frame(width: side, height: lyricsHeight ?? side)
        .nowPlayingProbe(lyricsHeight == nil ? "art" : "lyrics")
    }

    /// Lyrics mode (P6): the title and artist on one line. The star comes back with the art.
    private func compactMeta(_ song: Song) -> some View {
        let artist = Text(song.artist).font(.subheadline).foregroundStyle(themed.palette.ink2Color)
        return Text("\(Text(song.title).font(.headline))  ·  \(artist)")
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("\(song.title), \(song.artist)")
            .accessibilityIdentifier("np-title-compact")
    }

    private func setLyrics(_ on: Bool) {
        if reduceMotion { showsLyrics = on }
        else { withAnimation(.easeInOut(duration: 0.25)) { showsLyrics = on } }
    }

    private func topBar(_ song: Song) -> some View {
        HStack {
            closeButton
            Spacer()
            // R10: the album name opens the album.
            Button { if let album = links.album { open(album) } } label: {
                VStack(spacing: 1) {
                    Text("Playing from").font(.caption).foregroundStyle(themed.palette.ink2Color)
                    Text(song.album).font(.footnote.weight(.semibold)).lineLimit(1)
                }
                .frame(minHeight: Tokens.minHitSize)
                .contentShape(Rectangle())
            }
            .disabled(links.album == nil)
            .accessibilityElement(children: .combine)
            .accessibilityHint("Opens the album")
            .accessibilityIdentifier("np-album-link")
            Spacer()
            moreMenu(song)   // R9, in the slot that balanced the close button
        }
        .buttonStyle(.plain)
    }

    private func moreMenu(_ song: Song) -> some View {
        NowPlayingMoreMenu(song: song, lyricsMode: lyricsMode, links: links, open: open)
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
                // R10: the artist name opens the (primary) artist.
                Button { if let artist = links.artist { open(artist) } } label: {
                    Text(song.artist).font(.title3).foregroundStyle(themed.palette.ink2Color).lineLimit(ax ? nil : 1)
                        .multilineTextAlignment(.leading)
                }
                .buttonStyle(.plain)
                .disabled(links.artist == nil)
                .accessibilityHint("Opens the artist")
                .accessibilityIdentifier("np-artist-link")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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
            // Y3 (item 11): the hallmark follows what plays (none for a transcode), and the line says what you hear.
            let hearing = model.hearing(song)
            let hallmark = hearing.hallmark(model.quality(of: song))   // "Lossless soon" for a kept find (Task 6.2b)
            Group {
                if typeSize.isAccessibilitySize {
                    // Times on their own line, the hallmark below with the full width, so it never hyphenates.
                    VStack(spacing: Tokens.Spacing.xs) {
                        HStack { elapsedText; Spacer(); remainingText }
                        Hallmark(hallmark)
                    }
                } else {
                    HStack {
                        elapsedText
                        Spacer()
                        Hallmark(hallmark)
                        Spacer()
                        remainingText
                    }
                }
            }
            .font(theme.numberFont(.caption))
            .foregroundStyle(themed.palette.ink2Color)
            if let text = hearing.text {
                Text(text)
                    .font(.caption2)
                    .foregroundStyle(themed.palette.ink2Color)
                    .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                    .minimumScaleFactor(typeSize.isAccessibilitySize ? 1 : 0.8)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("now-playing-hearing")
            }
        }
    }

    /// Shuffle | previous | play | next | repeat (R6), spread across the width, so the row's height is unchanged (D43).
    private func transport(_ player: Player) -> some View {
        HStack(spacing: 0) {
            PlayerModeButton(kind: .shuffle)
            Spacer(minLength: 0)
            Button { player.previous() } label: {
                Image(systemName: "backward.fill").font(.title)
                    .frame(width: 60, height: 60)
            }
            .accessibilityLabel("Previous")
            Spacer(minLength: 0)
            Button { player.toggle() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 34))
                    .frame(width: 76, height: 76)
                    .background(themed.palette.solidSurfaceColor, in: Circle())
            }
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            .accessibilityIdentifier("np-play-pause")
            Spacer(minLength: 0)
            Button { player.next() } label: {
                Image(systemName: "forward.fill").font(.title)
                    .frame(width: 60, height: 60)
            }
            .accessibilityLabel("Next")
            Spacer(minLength: 0)
            PlayerModeButton(kind: .repeatMode)
        }
        .frame(maxWidth: .infinity)
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
