import DesignSystem
import SwiftUI

/// Connect when signed out; the tabs when signed in. Magic Tap toggles playback anywhere.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = model.theme
        Group {
            if model.session == nil, model.isWaitingForUnlock {
                ContentUnavailableView("Unlock to continue", systemImage: "lock",
                                       description: Text("Magpie will pick up where you left off once your iPhone is unlocked."))
            } else if model.session == nil {
                ConnectView()
            } else {
                MainTabs()
            }
        }
        .magpieTheme(theme)
        .tint(theme.colors(for: scheme).accentInkColor)
        .preferredColorScheme(theme.character == .immersive ? .dark : nil)
        .accessibilityAction(.magicTap) {
            if model.player.queue.current != nil { model.player.toggle() }
        }
    }
}

private enum AppTab: Hashable { case home, library, search }

/// Home · Library + Search, with the mini player above the tab bar while something is queued.
struct MainTabs: View {
    @Environment(AppModel.self) private var model
    @State private var tab: AppTab = .home
    @State private var showNowPlaying = false

    var body: some View {
        TabView(selection: $tab) {
            Tab("Home", systemImage: "house", value: AppTab.home) {
                NavigationStack { HomeView().magpieRoutes() }
            }
            Tab("Library", systemImage: "square.stack", value: AppTab.library) {
                NavigationStack { LibraryView().magpieRoutes() }
            }
            Tab(value: AppTab.search, role: .search) {
                SearchView()
            }
        }
        .tabViewBottomAccessory(isEnabled: model.player.queue.current != nil) {
            MiniPlayerAccessory { showNowPlaying = true }
        }
        .sheet(isPresented: $showNowPlaying) {
            NowPlayingView()
        }
    }
}

/// The design-system mini player fed from `Player`.
private struct MiniPlayerAccessory: View {
    @Environment(AppModel.self) private var model
    let open: () -> Void

    var body: some View {
        let player = model.player
        if let song = player.queue.current?.song {
            Artwork(song.coverArtId, side: 36) { image in
                MiniPlayer(title: song.title, artist: song.artist, artwork: image, isPlaying: player.isPlaying,
                           onPlayPause: { player.toggle() }, onNext: { player.next() }, onOpen: open)
            }
            .accessibilityIdentifier("mini-player")
        }
    }
}
