import AurralKit
import DesignSystem
import MagpieCore
import Playback
import Search
import SwiftUI

/// Round 14 A3 (owner answer 8, Decisions 1 and 4): an outside song's ⋯ menu, on Trending, the genre charts, the
/// Discover playlists, artist pages' Top songs and Search: **Listen to the full song** ("Goes into your Finds": the
/// existing Find), **Add artist** (the existing Add) and **Save to playlist** (Just this song / Whole artist, then the
/// playlist). Hidden without Lidarr (owner answer 9: Navidrome only, or with Aurral alone).
struct OutsideSongMenu: View {
    @Environment(AppModel.self) private var model
    let song: OutsideSong

    init(song: OutsideSong) { self.song = song }
    init(song: AurralSong) { self.song = OutsideSong(song) }

    @MainActor static func isAvailable(_ model: AppModel) -> Bool { model.outsideSongMenuAvailable }

    var body: some View {
        if model.outsideSongMenuAvailable {
            // Round 15 C3 (owner item 6, D135, D136, D139): where it stands, then Try (temporary) and Add to library
            // (permanent). With Allow changes off (or Try not set up) the subtitles and a tap say why.
            if let status = model.libraryStatus(for: song) {
                Label(status, systemImage: "clock").accessibilityIdentifier("song-menu-status")
            }
            if let stopped = model.stoppedRequest(for: song) {
                Button { Task { await model.retry(stopped) } } label: {
                    Label(LibraryFindsCopy.retry, systemImage: "arrow.clockwise")
                }
                .accessibilityIdentifier("song-menu-retry")
            }
            Button { Task { await model.tryOutside(song) } } label: {
                Label { Text(LibraryFindsCopy.tryIt); Text(Self.note(model, LibraryFindsCopy.tryNote)) } icon: {
                    Image(systemName: "sparkles")
                }
            }
            .accessibilityIdentifier("song-menu-try")
            Button { Task { await model.addToLibrary(song) } } label: {
                Label { Text(LibraryFindsCopy.addToLibrary); Text(Self.note(model, LibraryFindsCopy.addNote)) } icon: {
                    Image(systemName: "arrow.down.circle")
                }
            }
            .accessibilityIdentifier("song-menu-add-library")
            Button { Task { await model.addArtist(of: song) } } label: {
                Label(SongActionsCopy.addArtist, systemImage: "person.badge.plus")
            }
            .accessibilityIdentifier("song-menu-add-artist")
            Button { model.askToSave(song) } label: {
                Label(SongActionsCopy.saveToPlaylist, systemImage: "text.badge.plus")
            }
            .accessibilityIdentifier("song-menu-save")
        }
    }

    /// The action's subtitle, or why it can't be done right now (D139: never a dead button).
    @MainActor static func note(_ model: AppModel, _ normal: String) -> String {
        if case .explained(let why) = model.libraryActions { return why }
        return normal
    }
}

/// Round 15 C3 (owner item 6): an outside album's menu (a Trending tile, an outside artist page's row): where it stands,
/// Try (temporary) and Add to library (permanent). Hidden without Lidarr; explained without Allow changes.
struct OutsideAlbumMenu: View {
    @Environment(AppModel.self) private var model
    let album: OutsideAlbumRef

    var body: some View {
        if model.libraryActions != .hidden {
            if let status = model.libraryStatus(for: album) {
                Label(status, systemImage: "clock").accessibilityIdentifier("album-menu-status")
            }
            Button { Task { await model.tryOutsideAlbum(album) } } label: {
                Label { Text(LibraryFindsCopy.tryIt); Text(OutsideSongMenu.note(model, LibraryFindsCopy.tryNote)) } icon: {
                    Image(systemName: "sparkles")
                }
            }
            .accessibilityIdentifier("album-menu-try")
            Button { Task { await model.addAlbumToLibrary(album) } } label: {
                Label { Text(LibraryFindsCopy.addToLibrary); Text(OutsideSongMenu.note(model, LibraryFindsCopy.addAlbumNote)) } icon: {
                    Image(systemName: "arrow.down.circle")
                }
            }
            .accessibilityIdentifier("album-menu-add-library")
        }
    }
}

/// A picture Aurral named (Deezer's or Apple's), loaded with no login; the placeholder until then (or for good).
struct AurralArt: View {
    @Environment(AppModel.self) private var model
    let image: AurralImage?
    let side: CGFloat
    var circle = false
    /// B1 (owner item 4): an artist's MBID: without a picture from the server, the one the artist page shows (kept on
    /// the phone, so it is there at once next time).
    var artist: MBID? = nil
    /// B1: bumped by a pull to refresh, so a picture that failed is asked for again.
    var attempt = 0
    @State private var picture: UIImage?

    var body: some View {
        // Fix round (review minor 2): only memory while drawing; the phone's copy is read in the task.
        SleeveArt(image: (picture ?? artist.flatMap { model.recommendedArt.peek(.artist($0)) }.map { UIImage(cgImage: $0) })
                    .map { Image(uiImage: $0) }, side: side)
            .clipShape(circle ? AnyShape(Circle()) : AnyShape(Rectangle()))
            .accessibilityHidden(true)
            .task(id: "\(image?.raw ?? "")|\(artist?.rawValue ?? "")#\(attempt)") {
                // The copy on the phone first (review minor 3: also when the server named a picture), then the server's
                // picture, then the one the artist page shows.
                if let artist, let onPhone = await model.recommendedArt.cached(.artist(artist)) {
                    picture = UIImage(cgImage: onPhone)
                }
                if let found = await model.aurralArtwork(image, side: side) { picture = found; return }
                guard picture == nil, let artist, !model.isOffline else { return }
                if let found = await model.recommendedArt.image(.artist(artist)) { picture = UIImage(cgImage: found) }
            }
    }
}

/// A chart or Discover playlist song. One the library has plays the library's file (with the "In your library" tick);
/// any other has its preview button (none without previews) and, once A3 supplies it, the ⋯ menu.
struct ChartSongRow: View {
    @Environment(AppModel.self) private var model
    let song: ChartSong
    /// The library's copy, when it has one.
    let copy: Song?
    /// Plays the library's copies from this one (the caller's list).
    let playCopy: () -> Void
    var showsPosition = false
    @State private var picture: UIImage?
    private let themed = Themed()

    var body: some View {
        HStack(spacing: Tokens.Spacing.s) {
            if showsPosition, let position = song.position {
                VStack(spacing: 0) {
                    Text("\(position)").font(.subheadline.monospacedDigit().weight(.semibold))
                    if let move = song.movement.flatMap(DiscoverPagesCopy.movement) {
                        Text(move.text).font(.caption2.weight(.semibold)).foregroundStyle(themed.palette.ink2Color)
                            .accessibilityLabel(move.label)
                    }
                }
                .frame(minWidth: 28)
                .accessibilityElement(children: .combine)
            }
            row
        }
        .padding(.horizontal, Tokens.Spacing.margin)
        .padding(.vertical, Tokens.Spacing.xs)
        .task(id: song.artwork?.raw) { picture = await model.aurralArtwork(song.artwork, side: 48) }
    }

    @ViewBuilder private var row: some View {
        let art = picture.map { Image(uiImage: $0) }
        if copy != nil {
            Button(action: playCopy) {
                PreviewRow(title: song.title, artist: song.artist, artwork: art, inLibrary: true, status: nil, onPreview: {})
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(.isButton)
        } else {
            let item = model.previewItem(for: song)
            let status = model.previewsAvailable
                ? PreviewCopy.status(model.previewPlayer.state(for: item), player: model.previewPlayer) : nil
            if OutsideSongMenu.isAvailable(model) {
                PreviewRow(title: song.title, artist: song.artist, artwork: art, status: status,
                           onPreview: { model.togglePreview(item) }) { OutsideSongMenu(song: song.song) }
            } else {
                PreviewRow(title: song.title, artist: song.artist, artwork: art, status: status,
                           onPreview: { model.togglePreview(item) })
            }
        }
    }
}

/// A list of chart or Discover playlist songs, with each one the library has played from the library.
struct ChartSongList: View {
    @Environment(AppModel.self) private var model
    let songs: [ChartSong]
    var showsPosition = false
    var identifier = "chart-song"
    @State private var copies: [Int: Song] = [:]

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(songs.enumerated()), id: \.offset) { index, song in
                ChartSongRow(song: song, copy: copies[index], playCopy: { play(from: index) }, showsPosition: showsPosition)
                    .accessibilityIdentifier("\(identifier)-\(index)")
            }
        }
        .task(id: songs) { copies = await model.libraryCopies(of: songs) }
    }

    /// The library's copies in the list's order, from the tapped one.
    private func play(from index: Int) {
        let owned = copies.keys.sorted()
        guard let start = owned.firstIndex(of: index) else { return }
        model.play(owned.compactMap { copies[$0] }, startAt: start)
    }
}

/// The calm card a section shows while it has never loaded, or isn't ready on the server yet.
struct UpdatingCard: View {
    var text = DiscoverPagesCopy.updating
    private let themed = Themed()

    var body: some View {
        Label(text, systemImage: "clock.arrow.circlepath")
            .font(.subheadline).foregroundStyle(themed.palette.ink2Color)
            .padding(Tokens.Spacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(themed.palette.ink2Color.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, Tokens.Spacing.margin)
            .accessibilityIdentifier("aurral-updating")
    }
}

/// A section title for these pages.
struct PageSectionTitle: View {
    let title: String
    var subtitle: String?
    private let themed = Themed()

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).magpieDisplay(.title2).accessibilityAddTraits(.isHeader)
            if let subtitle { Text(subtitle).font(.footnote).foregroundStyle(themed.palette.ink2Color) }
        }
        .padding(.horizontal, Tokens.Spacing.margin)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
