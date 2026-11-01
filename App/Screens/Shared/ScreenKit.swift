import DesignSystem
import NavidromeKit
import Requests
import Search
import SwiftUI

/// Where a browse screen can take you.
enum Route: Hashable {
    case album(id: String)
    case artist(id: String)
    case playlist(id: String)
    case artists
    case albums
    case playlists
    /// Library › Requests (Activity).
    case requests
    case finds
    case request(RequestID)
    /// Home › Made for you (Task 7.1c).
    case madeForYou(MadeForYou.Playlist)
    /// Library › Downloads: what's on the phone (Task 14), and a playlist there: only its songs on the phone (T23).
    case downloads
    case downloadedPlaylist(id: String)
    /// Library › Genres, a group's page and a genre's page (Task 19).
    case genres
    case genreGroup(id: String)
    case genre(name: String)
    /// Library › Songs and Library › Favourites (Task 21).
    case songs
    case favourites
    /// R19: an artist or album that's not in the library, from MusicBrainz.
    case outsideArtist(NotYetArtist)
    case outsideAlbum(NotYetAlbum)
}

extension View {
    /// Pushes the screen for each `Route`.
    func magpieRoutes() -> some View {
        navigationDestination(for: Route.self) { route in
            switch route {
            case .album(let id): AlbumView(albumId: id)
            case .artist(let id): ArtistView(artistId: id)
            case .playlist(let id): PlaylistView(playlistId: id)
            case .artists: ArtistsListView()
            case .albums: AlbumsListView()
            case .playlists: PlaylistsListView()
            case .requests: ActivityView()
            case .finds: FindsView()
            case .request(let id): RequestDetailView(requestId: id)
            case .madeForYou(let playlist): MadeForYouView(playlist: playlist)
            case .downloads: DownloadsView()
            case .downloadedPlaylist(let id): PlaylistView(playlistId: id, fromPhone: true)
            case .genres: GenresView()
            case .genreGroup(let id): GenreGroupView(groupId: id)
            case .genre(let name): GenreView(name: name)
            case .songs: SongsListView()
            case .favourites: FavouritesView()
            case .outsideArtist(let artist): OutsideArtistView(artist: artist)
            case .outsideAlbum(let album): OutsideAlbumView(album: album)
            }
        }
    }

    /// The theme's page background behind scroll views and lists.
    func magpieScreen() -> some View { modifier(ScreenBackground()) }

    /// A large title set in the theme's display face (New York in Signature, SF in Classic).
    func magpieLargeTitle(_ title: String) -> some View {
        navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .largeTitle) {
                    Text(title).magpieDisplay(.largeTitle).accessibilityAddTraits(.isHeader)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
    }
}

private struct ScreenBackground: ViewModifier {
    @Environment(\.magpieTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background(theme.colors(for: scheme).bgColor.ignoresSafeArea())
    }
}

/// Current palette for app screens.
struct Themed: DynamicProperty {
    @Environment(\.magpieTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    var palette: Palette { theme.colors(for: scheme) }
}

/// Something loaded from the server.
enum Loadable<Value> {
    case loading
    case loaded(Value)
    case failed(String)

    var value: Value? { if case .loaded(let v) = self { return v } else { return nil } }
}

/// Spinner, the loaded content, or a plain failure with Try again.
struct LoadableView<Value, Content: View>: View {
    let state: Loadable<Value>
    let retry: () async -> Void
    @ViewBuilder let content: (Value) -> Content

    var body: some View {
        switch state {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, minHeight: 200)
        case .loaded(let value):
            content(value)
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't load this", systemImage: "wifi.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                Button("Try again") { Task { await retry() } }
            }
        }
    }
}

enum BrowseErrorCopy {
    static let unexpectedData = ConnectErrorCopy.unexpectedData
    static let unexpectedResponse = "Something in front of your music server answered instead of it. Check that its address still reaches the server directly."

    static func message(for error: Error) -> String {
        if case NavidromeError.unexpectedResponse = error { return unexpectedResponse }
        if case NavidromeError.unexpectedData = error { return unexpectedData }
        // The server answered and refused the saved password (T14: a refused reconnect isn't "offline").
        if case NavidromeError.badCredentials = error { return ConnectErrorCopy.badCredentials }
        return AppModel.isConnectionError(error)
            ? "Your music server isn't answering right now."
            : "Something went wrong. Try again in a moment."
    }
}

enum DurationText {
    /// `3:58`, `1:02:03`.
    static func clock(_ t: TimeInterval) -> String {
        // NaN or infinity shows 0:00 rather than trap in Int(_:).
        let s = t.isFinite ? Int(min(max(t, 0), 1e9).rounded(.down)) : 0
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }

    /// "3 minutes, 58 seconds" for VoiceOver.
    static func spoken(_ t: TimeInterval) -> String {
        // DateComponentsFormatter raises NSInternalInconsistencyException on NaN or infinity (crash hunt 4): spoken as
        // 0, as `clock` shows 0:00.
        let t = t.isFinite ? t : 0
        let f = DateComponentsFormatter()
        f.allowedUnits = t >= 3600 ? [.hour, .minute] : [.minute, .second]
        f.unitsStyle = .full
        return f.string(from: t) ?? ""
    }

    /// Whole minutes for album footers ("28 minutes").
    static func minutes(_ t: TimeInterval) -> Int { t.isFinite ? Int((min(max(t, -1e9), 1e9) / 60).rounded()) : 0 }
}
