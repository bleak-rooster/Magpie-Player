import DesignSystem
import SwiftUI

/// Connect when signed out; the tabs when signed in. Magic Tap toggles playback anywhere.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    @Environment(\.scenePhase) private var scenePhase

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
        .onChange(of: scenePhase, initial: true) { _, phase in model.isForeground = phase == .active }
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

/// The design-system mini player fed from `Player`. While a find that just became ready waits next in the queue
/// (D6), the accessory offers it instead: "<song> is ready", Play now.
private struct MiniPlayerAccessory: View {
    @Environment(AppModel.self) private var model
    let open: () -> Void

    var body: some View {
        let player = model.player
        if let banner = model.visibleBanner {
            PlayNowBannerView(banner: banner)
        } else if let song = player.queue.current?.song {
            Artwork(song.coverArtId, side: 36) { image in
                MiniPlayer(title: song.title, artist: song.artist, artwork: image, isPlaying: player.isPlaying,
                           onPlayPause: { player.toggle() }, onNext: { player.next() }, onOpen: open)
            }
            .accessibilityIdentifier("mini-player")
        }
    }
}

/// D6: the in-app "Play now" banner. Text and symbol, not shape alone (D3); Play now and Not now are their own
/// buttons, and VoiceOver offers Play now as the default action.
private struct PlayNowBannerView: View {
    @Environment(AppModel.self) private var model
    let banner: PlayNowBanner
    private let themed = Themed()

    var body: some View {
        let p = themed.palette
        HStack(spacing: 10) {
            Image(systemName: "record.circle").font(.title2).foregroundStyle(p.accentInkColor)
                .frame(width: 36, height: 36)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(LandingCopy.title(banner.song)).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(LandingCopy.upNext).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            Button(LandingCopy.playNow) { model.playNow(banner) }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .frame(minHeight: Tokens.minHitSize)
                .accessibilityAddTraits(.startsMediaSession)
                .accessibilityIdentifier("play-now")
            Button { model.dismissBanner() } label: {
                Image(systemName: "xmark").font(.footnote.weight(.semibold))
                    .frame(width: Tokens.minHitSize, height: Tokens.minHitSize).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Not now")
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .frame(minHeight: 52)
        // The accessory is a fixed-height bar: like the mini player, its text stops growing at xxxLarge (H3 I3).
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .accessibilityShowsLargeContentViewer { Text(LandingCopy.title(banner.song)) }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: LandingCopy.playNow) { model.playNow(banner) }
        .accessibilityIdentifier("play-now-banner")
    }
}
