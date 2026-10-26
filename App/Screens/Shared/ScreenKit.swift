import DesignSystem
import Requests
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
    case request(RequestID)
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
            case .request(let id): RequestDetailView(requestId: id)
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
    static func message(for error: Error) -> String {
        AppModel.isConnectionError(error)
            ? "Your music server isn't answering right now."
            : "Something went wrong. Try again in a moment."
    }
}

enum DurationText {
    /// `3:58`, `1:02:03`.
    static func clock(_ t: TimeInterval) -> String {
        let s = max(0, Int(t.rounded(.down)))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }

    /// "3 minutes, 58 seconds" for VoiceOver.
    static func spoken(_ t: TimeInterval) -> String {
        let f = DateComponentsFormatter()
        f.allowedUnits = t >= 3600 ? [.hour, .minute] : [.minute, .second]
        f.unitsStyle = .full
        return f.string(from: t) ?? ""
    }

    /// Whole minutes for album footers ("28 minutes").
    static func minutes(_ t: TimeInterval) -> Int { Int((t / 60).rounded()) }
}
