import DesignSystem
import MagpieCore
import Playback
import SwiftUI

/// Now Playing sheet: art, title, artist, star, scrubber (rounded numerals, hallmark), transport,
/// Up next, and Lyrics / Queue. Signature has a "Playing from" top bar; Classic a grabber only.
struct NowPlayingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.magpieTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var scrubbing: TimeInterval?
    @State private var panel: Panel?
    /// The server advertises `songLyrics` (A13); the Lyrics button is hidden until it does.
    @State private var lyricsAvailable = false
    private let themed = Themed()

    private enum Panel: String, Identifiable { case lyrics, queue; var id: String { rawValue } }

    var body: some View {
        let p = themed.palette
        let player = model.player
        Group {
            if let song = player.queue.current?.song {
                ScrollView {
                    VStack(spacing: Tokens.Spacing.xl) {
                        if theme.character != .classic { topBar(song) }
                        Artwork(song.coverArtId, side: 340) { image in
                            SleeveArt(image: image, side: nil)
                                .aspectRatio(1, contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.hero, style: .continuous))
                                .frame(maxWidth: 360)
                        }
                        .shadow(color: .black.opacity(0.22), radius: 24, y: 12)
                        .scaleEffect(player.isPlaying ? 1 : 0.92)
                        .animation(.spring(duration: 0.4), value: player.isPlaying)
                        meta(song)
                        scrubber(song, player)
                        if let error = player.lastError {
                            Label("This song didn't play. Try it again, or skip to the next one.",
                                  systemImage: "exclamationmark.triangle")
                                .font(.footnote).foregroundStyle(p.ink2Color)
                                .accessibilityHint(error)
                        }
                        transport(player)
                        if let next = player.queue.upcoming.first?.song { upNext(next) }
                        bottomBar
                    }
                    .padding(.horizontal, Tokens.Spacing.xxl)
                    .padding(.vertical, Tokens.Spacing.l)
                }
            } else {
                ContentUnavailableView("Nothing playing", systemImage: "music.note")
            }
        }
        .foregroundStyle(p.inkColor)
        .background { ArtBackdrop(coverArtId: model.player.queue.current?.song.coverArtId) }
        .presentationDragIndicator(theme.character == .classic ? .visible : .hidden)
        .task { lyricsAvailable = (try? await model.serverAdvertises("songLyrics")) ?? false }
        .sheet(item: $panel) { panel in
            switch panel {
            case .lyrics: LyricsView()
            case .queue: QueueView()
            }
        }
    }

    private func topBar(_ song: Song) -> some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.down").font(.title3.weight(.semibold))
                    .frame(width: Tokens.minHitSize, height: Tokens.minHitSize)
            }
            .accessibilityLabel("Close Now Playing")
            Spacer()
            VStack(spacing: 1) {
                Text("Playing from").font(.caption).foregroundStyle(themed.palette.ink2Color)
                Text(song.album).font(.footnote.weight(.semibold)).lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            Spacer()
            Color.clear.frame(width: Tokens.minHitSize, height: Tokens.minHitSize)
        }
        .buttonStyle(.plain)
    }

    private func meta(_ song: Song) -> some View {
        let starred = model.isStarred(song)
        return HStack(alignment: .center, spacing: Tokens.Spacing.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title).magpieDisplay(.title2).lineLimit(2)
                    .accessibilityIdentifier("np-title")
                Text(song.artist).font(.title3).foregroundStyle(themed.palette.ink2Color).lineLimit(1)
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
            HStack {
                Text(DurationText.clock(elapsed)).accessibilityHidden(true)   // the slider speaks the time
                Spacer()
                Hallmark(model.quality(of: song))   // "Lossless soon" for a kept find (Task 6.2b)
                Spacer()
                Text("-" + DurationText.clock(duration - elapsed)).accessibilityHidden(true)
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
        Button { panel = .queue } label: {
            HStack(spacing: Tokens.Spacing.m) {
                Artwork(song.coverArtId, side: 36) { SleeveArt(image: $0, side: 36) }
                Text("Up next").font(.footnote.weight(.semibold)).foregroundStyle(themed.palette.ink2Color)
                Text(song.title).font(.footnote).lineLimit(1)
                Spacer()
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

    private var bottomBar: some View {
        HStack {
            if lyricsAvailable {
                Button { panel = .lyrics } label: {
                    Image(systemName: "quote.bubble").font(.title3).frame(width: Tokens.minHitSize, height: Tokens.minHitSize)
                }
                .accessibilityLabel("Lyrics")
            }
            Spacer()
            Button { panel = .queue } label: {
                Image(systemName: "list.bullet").font(.title3).frame(width: Tokens.minHitSize, height: Tokens.minHitSize)
            }
            .accessibilityLabel("Queue")
        }
        .buttonStyle(.plain)
        .foregroundStyle(themed.palette.ink2Color)
        .padding(.horizontal, Tokens.Spacing.xxl)
    }
}
