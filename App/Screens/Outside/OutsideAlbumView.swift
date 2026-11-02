import DesignSystem
import MagpieCore
import Requests
import Search
import SwiftUI

/// R19: an album that's not in the library. The cover (R15, memory only), the tracklist of the release Magpie picks,
/// Try this album (into Finds when set up), Add <artist> to your library (R18, through the gate; an owner's artist is
/// never changed), and Try on each track. A live request shows its status and opens its page (R17); tracks that land
/// turn into library songs in place.
struct OutsideAlbumView: View {
    @Environment(AppModel.self) private var app
    let album: NotYetAlbum
    @State private var model: OutsideAlbumModel?
    @State private var art: OutsideArtLoader?
    @State private var trying: TryTarget?
    private let themed = Themed()

    var body: some View {
        ScrollView {
            if let model { content(model) }
        }
        .navigationTitle(album.title)
        .navigationBarTitleDisplayMode(.inline)
        .magpieScreen()
        .sheet(item: $trying) { TrySheet(target: $0) }
        // One task builds and loads (review I2); again when offline mode flips.
        .task(id: app.isOffline) {
            if art == nil { art = app.makeOutsideArt() }
            _ = await OutsideAlbumModel.open(model, app: app, album: album) { model = $0 }
        }
        // R17: something for this album is Ready: the library is asked again, and its tracks become library songs.
        .task(id: model?.landingKey ?? []) { await model?.refreshLanded() }
        .onDisappear { art?.reset() }
    }

    private func content(_ model: OutsideAlbumModel) -> some View {
        let p = themed.palette
        return VStack(alignment: .leading, spacing: Tokens.Spacing.xl) {
            VStack(spacing: Tokens.Spacing.m) {
                OutsideArtwork(art, key: album.mbid.map(OutsideArtKey.releaseGroup)) { image in
                    SleeveArt(image: image, placeholder: p.surfaceColor, side: 220)
                        .recordBadge(RowState.notYet.statusSymbol, size: 26)
                }
                .accessibilityHidden(true)
                Text(album.title).magpieDisplay(.title).multilineTextAlignment(.center).accessibilityAddTraits(.isHeader)
                Text(([album.kind ?? "Album", album.artist] + [album.year.map(String.init)].compactMap { $0 })
                        .joined(separator: " \u{00B7} "))
                    .font(.subheadline).foregroundStyle(p.ink2Color).multilineTextAlignment(.center)
                if let request = model.albumRequest {
                    // R17: on its way: its status, opening its page; never a second Try.
                    NavigationLink(value: Route.request(request.id)) {
                        Label(RequestCopy.status(request, context: app.waitContext), systemImage: RequestCopy.symbol(request))
                            .font(.subheadline).foregroundStyle(p.accentInkColor)
                            .frame(minHeight: Tokens.minHitSize)
                    }
                    .accessibilityIdentifier("outside-album-request")
                } else {
                    StatusLine(.notYet)
                    if model.phase == .loaded, model.canTryAlbum, let target = model.tryTarget {
                        // Y7: the page's one action, in the same bar as Play on an album page.
                        ActionBar(insetsMargins: false) {
                            ActionButton(TrySheet.tryAlbumTitle, symbol: "sparkles", prominence: .primary) { trying = target }
                                .accessibilityIdentifier("outside-album-try")
                        }
                    }
                }
                if let presentation = model.lidarrLine.presentation, model.phase != .offline {
                    ArtistLidarrLine(line: model.lidarrLine, presentation: presentation,
                                     addTitle: NewMusicCopy.addTitle(album.artist))
                }
                if let artistMBID = album.artistMBID {
                    NavigationLink(value: Route.outsideArtist(NotYetArtist(name: album.artist, mbid: artistMBID))) {
                        Text("More by \(album.artist)").font(.subheadline).frame(minHeight: Tokens.minHitSize)
                    }
                    .tint(p.accentInkColor)
                    .accessibilityIdentifier("outside-album-artist")
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Tokens.Spacing.margin)

            switch model.phase {
            case .loading:
                ProgressView().frame(maxWidth: .infinity, minHeight: 120)
            case .offline:
                OfflineNotice().frame(maxWidth: .infinity).accessibilityIdentifier("outside-offline")
            case .failed:
                OutsideFailed { Task { await model.load() } }
            case .loaded:
                tracklist(model)
            }
        }
        .padding(.vertical, Tokens.Spacing.l)
        .foregroundStyle(p.inkColor)
    }

    @ViewBuilder private func tracklist(_ model: OutsideAlbumModel) -> some View {
        if model.tracks.isEmpty {
            Text("MusicBrainz has no tracklist for this album yet.").font(.body).foregroundStyle(themed.palette.ink2Color)
                .frame(maxWidth: .infinity).padding(.horizontal, Tokens.Spacing.margin)
        } else {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(model.tracks.enumerated()), id: \.offset) { index, track in
                    trackRow(model, index: index, track: track).accessibilityIdentifier("outside-track-\(index)")
                }
            }
        }
    }

    @ViewBuilder private func trackRow(_ model: OutsideAlbumModel, index: Int, track: ExternalRecording) -> some View {
        switch model.row(index) {
        case .library(let song):
            Button { app.play([song], startAt: 0) } label: {
                Artwork(song.coverArtId, side: 48) { SongRow(song: song, state: .library, artwork: $0) }
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(.isButton)
        case .request(let id):
            if let request = app.magpieRequest(id) {
                NavigationLink(value: Route.request(id)) {
                    RequestRow(request: request, context: app.waitContext)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, Tokens.Spacing.margin)
            }
        case .tryIt:
            let song = Song(id: "outside-\(index)", title: track.title, artist: track.artist, album: album.title,
                            duration: track.duration ?? 0)
            SongRow(song: song, state: RequestCopy.rowState(for: track, in: app.requests),
                    tryTitle: RequestCopy.tryTitle(app.tryAvailability),
                    onTry: { trying = TryTarget(recording: track, releaseGroup: album.mbid) })
        }
    }
}
