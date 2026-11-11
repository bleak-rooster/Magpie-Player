import DesignSystem
import MagpieCore
import Requests
import Search
import SwiftUI

/// R19: an artist that's not in the library (from search). Styled like the library Artist page: the picture (R15,
/// memory only) and the name, the Lidarr status line with Add to your library (W3, R18), then Albums, EPs and Singles
/// (studio releases), and More for live albums, compilations and the rest. Each album opens its outside page, and
/// offers Try this album on a long press; an album already on its way shows its request instead (R17).
struct OutsideArtistView: View {
    @Environment(AppModel.self) private var app
    let artist: NotYetArtist
    @State private var model: OutsideArtistModel?
    @State private var art: OutsideArtLoader?
    @State private var showsMore = false
    /// Round 14 A3 (owner answer 6): the artist's Top songs, from the chosen source (the page's Popular).
    @State private var topSongs: TopSongsResult?
    /// Round 26 K2 (D267): an artist Lidarr has gets the same Top songs as their library page (the saved list by MBID).
    @State private var lidarrTop: LidarrTopSongsModel?
    /// B1: bumped by a pull to refresh, so every picture that didn't load is asked for again.
    @State private var artAttempt = 0
    private let themed = Themed()

    var body: some View {
        ScrollView {
            if let model { content(model) }
        }
        // B1 (owner item 6, D77): pull to refresh reads the albums, the top songs and every missing picture again.
        .refreshable {
            await RefreshSafety.run {
                guard !app.isOffline else { return }
                artAttempt += 1
                // Second fix round (re-review minor 6): top songs have their own bound too.
                async let songs: Void = loadTopSongs(fresh: true)
                if let model { await model.load(fresh: true) }
                await songs
            }
        }
        .navigationTitle(artist.name)
        .navigationBarTitleDisplayMode(.inline)
        .magpieScreen()
        // One task builds and loads (review I2); again when offline mode flips ("You're offline", then the page).
        .task(id: app.isOffline) {
            if art == nil { art = app.makeOutsideArt() }
            let opened = await OutsideArtistModel.open(model, app: app, artist: artist) { shown in
                shown.willShowSections = { sections in noteAlbums(sections) }   // before the rows ask for covers
                model = shown
            }
            noteAlbums(opened.sections)
        }
        .task(id: app.isOffline) { await loadTopSongs(fresh: false) }
        .onDisappear { art?.reset() }   // R15: the outside art goes with the page
    }

    private func content(_ model: OutsideArtistModel) -> some View {
        let p = themed.palette
        return VStack(alignment: .leading, spacing: Tokens.Spacing.xxl) {
            VStack(spacing: Tokens.Spacing.m) {
                OutsideArtwork(art, key: artist.mbid.map(OutsideArtKey.artist), attempt: artAttempt) { image in
                    SleeveArt(image: image, placeholder: p.surfaceColor, side: 180)
                        .overlay { if image == nil { ArtistMonogram(name: artist.name) } }
                        .clipShape(Circle())
                }
                .accessibilityHidden(true)
                Text(artist.name).magpieDisplay(.largeTitle).multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                StatusLine(.notYet)
                if let presentation = model.lidarrLine.presentation, model.phase != .offline {
                    ArtistLidarrLine(line: model.lidarrLine, presentation: presentation)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Tokens.Spacing.margin)

            switch model.phase {
            case .loading:
                ProgressView().frame(maxWidth: .infinity, minHeight: 120)
            case .offline:
                if let lidarrTop, lidarrTop.showsList { LidarrTopSongsSection(songs: lidarrTop.songs) }   // D268
                OfflineNotice().frame(maxWidth: .infinity).accessibilityIdentifier("outside-offline")
            case .failed:
                OutsideFailed { Task { await model.load() } }
            case .loaded:
                if let lidarrTop, lidarrTop.showsList {   // Round 26 K2 (D267)
                    LidarrTopSongsSection(songs: lidarrTop.songs)
                } else if let topSongs {
                    TopSongsSection(result: topSongs)
                }
                sections(model)
            }
        }
        .padding(.vertical, Tokens.Spacing.l)
        .foregroundStyle(p.inkColor)
    }

    @ViewBuilder private func sections(_ model: OutsideArtistModel) -> some View {
        let s = model.sections
        if s.isEmpty {
            Text("MusicBrainz lists no albums for \(artist.name).").font(.body).foregroundStyle(themed.palette.ink2Color)
                .frame(maxWidth: .infinity).padding(.horizontal, Tokens.Spacing.margin)
        }
        section("Albums", s.albums, model, id: "outside-albums")
        section("EPs", s.eps, model, id: "outside-eps")
        section("Singles", s.singles, model, id: "outside-singles")
        if !s.more.isEmpty {
            VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
                Button { withAnimation { showsMore.toggle() } } label: {
                    HStack {
                        Text("More").magpieDisplay(.title2)
                        Spacer()
                        Image(systemName: showsMore ? "chevron.up" : "chevron.down").accessibilityHidden(true)
                    }
                    .frame(minHeight: Tokens.minHitSize)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(.isHeader)
                .accessibilityValue(showsMore ? "Expanded" : "Collapsed")
                .accessibilityHint("Live albums, compilations and the rest")
                .accessibilityIdentifier("outside-more")
                .padding(.horizontal, Tokens.Spacing.largeTitleMargin)
                if showsMore { rows(s.more, model, id: "outside-more") }
            }
        }
    }

    @ViewBuilder private func section(_ title: String, _ items: [OutsideArtistSections.Item], _ model: OutsideArtistModel,
                                      id: String) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
                Text(title).magpieDisplay(.title2).accessibilityAddTraits(.isHeader)
                    .padding(.horizontal, Tokens.Spacing.largeTitleMargin)
                rows(items, model, id: id)
            }
        }
    }

    private func rows(_ items: [OutsideArtistSections.Item], _ model: OutsideArtistModel, id: String) -> some View {
        LazyVStack(alignment: .leading, spacing: Tokens.Spacing.m) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                albumRow(model.album(item), item: item).accessibilityIdentifier("\(id)-\(index)")
            }
        }
        .padding(.horizontal, Tokens.Spacing.margin)
    }

    @ViewBuilder private func albumRow(_ album: NotYetAlbum, item: OutsideArtistSections.Item) -> some View {
        let detail = [item.kind, item.year.map(String.init)].compactMap { $0 }.joined(separator: " \u{00B7} ")
        if let request = RequestLinks.request(releaseGroup: item.id, in: app.requests) {   // R17: back to its request
            RequestedItemRow(title: item.title, detail: detail, request: request)
                .buttonStyle(.plain)
        } else {
            NavigationLink(value: Route.outsideAlbum(album)) {
                OutsideArtwork(art, key: .releaseGroup(item.id), attempt: artAttempt) { image in
                    NotYetAlbumRow(title: item.title, detail: detail,
                                   label: [item.title, item.kind, item.year.map(String.init)].compactMap { $0 }.joined(separator: ", "),
                                   artwork: image)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu {
                // Round 15 C3: Try (temporary) / Add to library (permanent), in place of Try this album.
                if !app.isOffline, model?.canTryAlbum(item) ?? false { OutsideAlbumMenu(album: OutsideAlbumRef(album)) }
            }
        }
    }

    /// Round 26 K2 (D267, D268): with Lidarr, the saved list at once, then Lidarr's answer for the artist (at most 10 s):
    /// an artist Lidarr has gets their list refreshed (`fresh`: a pull, whatever the two-minute gap); otherwise, or with
    /// no list, the ordinary Top songs as before. Offline only the saved songs on the phone show and nothing is read.
    private func loadTopSongs(fresh: Bool) async {
        if app.lidarr == nil || lidarrTop?.offline != false {
            lidarrTop = await app.lidarrTopSongs(name: artist.name, mbid: artist.mbid, artistId: nil)
        }
        guard !app.isOffline else { return }
        if let lidarrTop {
            let (name, mbid) = (artist.name, artist.mbid)
            await lidarrTop.run(fresh: fresh) {
                ((try? await app.artistLidarrState(name: name, mbid: mbid)) ?? nil).map { .answered($0) } ?? .unread
            }
            guard lidarrTop.wantsOrdinary else { return }
        }
        let (name, mbid) = (artist.name, artist.mbid)
        let songs = await Deadline.run(OutsideArtistModel.defaultLoadTimeout) { @MainActor in
            await app.artistTopSongs(name: name, mbid: mbid)
        }
        if case .success(let found) = songs, found != nil || !fresh { topSongs = found }
    }

    /// D125: each album's title and artist, for the cover source that finds covers by name.
    private func noteAlbums(_ s: OutsideArtistSections) {
        for item in s.albums + s.eps + s.singles + s.more {
            art?.note(item.id, OutsideAlbumHint(title: item.title, artist: artist.name))
        }
    }
}

enum OutsideCopy {
    static let couldntLoad = "Couldn't reach MusicBrainz. Try again in a moment."
}

/// MusicBrainz couldn't be read: says so calmly, with Try again.
struct OutsideFailed: View {
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Couldn't load this page", systemImage: "wifi.exclamationmark")
        } description: {
            Text(OutsideCopy.couldntLoad)
        } actions: {
            Button("Try again", action: retry)
        }
        .accessibilityIdentifier("outside-failed")
    }
}
