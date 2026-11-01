import DesignSystem
import MagpieCore
import Playback
import SwiftUI

/// Album: sleeve art, title in the display face, artist, year and hallmark, Play / Shuffle, tracks.
struct AlbumView: View {
    @Environment(AppModel.self) private var model
    let albumId: String
    @State private var album: Loadable<Album> = .loading
    /// Whether what is shown came from the phone (offline) or the server; a change of offline mode loads again.
    @State private var loadedOffline: Bool?
    private let themed = Themed()

    var body: some View {
        ScrollView {
            LoadableView(state: album, retry: load) { album in
                content(album)
            }
        }
        .navigationTitle(album.value?.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // R7, R8 (the UX appraisal's header): Favourite and ⋯ in the toolbar; Download stays the capsule.
            if let album = album.value, !model.isOffline, !OfflineCatalog.isLocalId(album.id) {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    FavouriteButton(target: .album(album.id))
                    AlbumMoreMenu(album: album)
                }
            }
        }
        .background { ArtBackdrop(coverArtId: album.value?.coverArtId) }
        .magpieScreen()
        // Again when offline mode changes, and offline when songs land on or leave the phone (the store may be
        // unreadable before first unlock): the phone's copy offline, the server's online.
        .task(id: model.offlinePageKey) {
            if album.value == nil || loadedOffline != model.isOffline || model.isOffline { await load() }
        }
    }

    private func content(_ album: Album) -> some View {
        let p = themed.palette
        let songs = album.songs ?? []
        return VStack(spacing: Tokens.Spacing.l) {
            VStack(spacing: Tokens.Spacing.s) {
                Artwork(album.coverArtId, side: 260) { SleeveArt(image: $0, side: 260) }
                    .reloadArtworkMenu(album.coverArtId)
                    .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
                    .padding(.bottom, Tokens.Spacing.s)
                Text(album.name)
                    .magpieDisplay(.title)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                if let artistId = album.artistId {
                    NavigationLink(value: Route.artist(id: artistId)) {
                        Text(album.artist).font(.title3).foregroundStyle(p.accentInkColor)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("album-artist")
                } else {
                    Text(album.artist).font(.title3).foregroundStyle(p.ink2Color)
                }
                HStack(spacing: Tokens.Spacing.s) {
                    if let year = album.year { Text(String(year)).font(theme.numberFont(.footnote)) }
                    if let quality = Self.quality(of: songs) { Hallmark(quality) }
                }
                .foregroundStyle(p.ink2Color)
                DownloadMarkLine(model.downloadIndex.mark(album: album))
            }
            .padding(.horizontal, Tokens.Spacing.largeTitleMargin)

            PlayShuffleButtons(songs: songs)
            DownloadButton(reason: .album(album.id), songs: songs, coverArtId: album.coverArtId)

            TrackList(songs: songs)

            if !songs.isEmpty {
                let minutes = DurationText.minutes(album.duration > 0 ? album.duration : songs.reduce(0) { $0 + $1.duration })
                Text("\(songs.count) \(songs.count == 1 ? "song" : "songs"), \(minutes) \(minutes == 1 ? "minute" : "minutes")")
                    .font(theme.numberFont(.footnote))
                    .foregroundStyle(p.ink2Color)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Tokens.Spacing.margin)
            }
        }
        .padding(.vertical, Tokens.Spacing.l)
        .foregroundStyle(p.inkColor)
    }

    @Environment(\.magpieTheme) private var theme

    /// The album's hallmark when every track shares one (e.g. all FLAC → Lossless).
    static func quality(of songs: [Song]) -> Quality? {
        let all = Set(songs.map { Quality.from(suffix: $0.suffix, bitRate: $0.bitRate) })
        guard all.count == 1, let q = all.first, q != .standard else { return nil }
        return q
    }

    private func load() async {
        loadedOffline = model.isOffline
        // Offline (Task 14), or an album the catalog grouped itself: the downloaded songs, from the phone.
        if model.isOffline || OfflineCatalog.isLocalId(albumId) {
            guard let local = await model.offlineCatalog.album(id: albumId) else {
                album = .failed(OfflineCopy.notOnPhone)
                return
            }
            album = .loaded(local)
            return
        }
        do {
            let loaded = try await model.request { [albumId] in try await $0.album(id: albumId) }
            album = .loaded(loaded)
            model.noteAlbumSongCounts([loaded])   // P1: backfills downloads saved without the album's count
            model.noteFavourite(.album(loaded.id), loaded.starred)   // R7
        } catch {
            album = .failed(BrowseErrorCopy.message(for: error))
        }
    }
}

/// Play and Shuffle capsules, side by side (stacked at accessibility sizes).
struct PlayShuffleButtons: View {
    @Environment(AppModel.self) private var model
    let songs: [Song]

    var body: some View {
        CapsuleRow {
            wide("Play", symbol: "play.fill") { model.play(songs, startAt: 0) }
            wide("Shuffle", symbol: "shuffle") { model.shuffle(songs) }
        }
        .disabled(songs.isEmpty)
        .padding(.horizontal, Tokens.Spacing.margin)
    }

    private func wide(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        CapsuleButton(title, symbol: symbol, action: action)
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier(title.lowercased())
    }
}

/// Numbered tracks with durations; the playing one shows a speaker instead of its number.
/// Disc headings appear when the album has more than one disc.
private struct TrackList: View {
    @Environment(AppModel.self) private var model
    @Environment(\.magpieTheme) private var theme
    let songs: [Song]
    @State private var removing: Song?
    private let themed = Themed()

    var body: some View {
        let p = themed.palette
        let discs = Set(songs.compactMap(\.disc))
        LazyVStack(spacing: 0) {
            ForEach(Array(songs.enumerated()), id: \.offset) { index, song in
                if discs.count > 1, song.disc != nil, index == 0 || songs[index - 1].disc != song.disc {
                    Text("Disc \(song.disc ?? 1)")
                        .font(.footnote.weight(.semibold)).foregroundStyle(p.ink2Color)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Tokens.Spacing.margin).padding(.top, Tokens.Spacing.l)
                        .accessibilityAddTraits(.isHeader)
                }
                row(index, song)
                Divider().overlay(p.sepColor).padding(.leading, 52)
            }
        }
        .songRemovalDialog($removing)
    }

    private func row(_ index: Int, _ song: Song) -> some View {
        let p = themed.palette
        let isCurrent = model.player.queue.current?.song.id == song.id
        let mark: DownloadMark = model.downloadIndex.isDownloaded(song.id) ? .downloaded : .none
        return Button {
            model.play(songs, startAt: index)
        } label: {
            HStack(spacing: Tokens.Spacing.m) {
                Group {
                    if isCurrent {
                        Image(systemName: model.player.isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                            .foregroundStyle(p.accentInkColor)
                    } else {
                        Text(song.track.map(String.init) ?? "").font(theme.numberFont(.callout))
                            .foregroundStyle(p.ink2Color)
                    }
                }
                .frame(width: 24)
                Text(song.title).font(.body).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                DownloadMarkView(mark)
                Text(DurationText.clock(song.duration)).font(theme.numberFont(.footnote))
                    .foregroundStyle(p.ink2Color)
            }
            .padding(.horizontal, Tokens.Spacing.margin)
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(song.title)
        .accessibilityValue(mark.joined(to: isCurrent ? "Now playing, \(DurationText.spoken(song.duration))"
                                                      : DurationText.spoken(song.duration)))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("track-\(index)")
        .contextMenu { SongDownloadMenuItem(song: song, removing: $removing) }
    }
}
