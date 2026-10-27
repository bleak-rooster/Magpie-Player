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
            PlayNowBannerView(banner: banner, open: open)
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
/// buttons. It stands in for the mini player, so it keeps what the mini player gives (final fix 2 B-M4): a tap on
/// its text opens Now Playing, and while another song plays, a pause button. For VoiceOver it is one element whose
/// default action is Play now (B-M9); Open Now Playing, Pause or Play, and Not now are its named actions.
private struct PlayNowBannerView: View {
    @Environment(AppModel.self) private var model
    let banner: PlayNowBanner
    let open: () -> Void
    private let themed = Themed()

    var body: some View {
        let p = themed.palette
        let player = model.player
        // The idle landing: the find itself is loaded and Play now plays it; nothing else to pause.
        let showsPause = !banner.idle && player.queue.current != nil
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "record.circle").font(.title2).foregroundStyle(p.accentInkColor)
                    .frame(width: 30, height: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text(LandingCopy.title(banner.song)).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(LandingCopy.upNext).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: Tokens.minHitSize)
            .contentShape(Rectangle())
            .onTapGesture(perform: open)
            if showsPause {
                Button { player.toggle() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.body)
                        .frame(width: 36, height: Tokens.minHitSize).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("play-now-banner-pause")
            }
            Button(LandingCopy.playNow) { model.playNow(banner) }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .frame(minHeight: Tokens.minHitSize)
            Button { model.dismissBanner() } label: {
                Image(systemName: "xmark").font(.footnote.weight(.semibold))
                    .frame(width: 36, height: Tokens.minHitSize).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .frame(minHeight: 52)
        // The accessory is a fixed-height bar: like the mini player, its text stops growing at xxxLarge (H3 I3).
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .accessibilityShowsLargeContentViewer { Text(LandingCopy.title(banner.song)) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(LandingCopy.title(banner.song)). \(LandingCopy.upNext)")
        .accessibilityAddTraits([.isButton, .startsMediaSession])
        .accessibilityHint("Plays it now.")
        .accessibilityAction { model.playNow(banner) }
        .accessibilityAction(named: LandingCopy.playNow) { model.playNow(banner) }
        .accessibilityAction(named: "Open Now Playing", open)
        .accessibilityActions {
            if showsPause {
                Button(player.isPlaying ? "Pause" : "Play") { player.toggle() }
            }
        }
        .accessibilityAction(named: "Not now") { model.dismissBanner() }
        .accessibilityIdentifier("play-now-banner")
    }
}
