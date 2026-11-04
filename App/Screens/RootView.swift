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
                    .environment(\.songIsDownloaded, model.songIsDownloaded)   // P1: every song row's mark
                    .libraryEditsPresenter()   // R7, R8: Add to playlist from menus, and the library's notices
                    .immersiveArt(coverArtId: model.player.queue.current?.song.coverArtId)   // R13: what's playing colours the app
            }
        }
        .magpieTheme(theme)
        .tint(theme.colors(for: scheme).accentInkColor)
        .preferredColorScheme(theme.character == .immersive ? .dark : nil)
        .accessibilityAction(.magicTap) {
            if model.player.queue.current != nil { model.player.toggle() }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            model.isForeground = phase == .active
            model.scenePhaseChanged(phase)   // P1: downloads wait while Magpie is in the background
            model.requestsScenePhaseChanged(phase)   // R16: a background pass while requests are on their way
            // T3 fix round 2: each activation (cold launches too) while Local Network is off re-checks silently.
            if phase == .active { Task { await model.localNetwork.recheckIfDenied() } }
            // Round 14 fix M3: Aurral's capabilities and this user's permissions, fresh at launch and on return.
            if phase == .active { Task { await model.refreshAurralCapabilities() } }
        }
        // T3 (spec §8): once per install, whatever the first screen is, so Magpie is listed under Local Network.
        .task { await model.localNetwork.requestAtFirstLaunch() }
    }
}

/// Home · Library + Search, with the mini player above the tab bar while something is queued.
struct MainTabs: View {
    @Environment(AppModel.self) private var model
    @State private var navigator = TabNavigator()
    @State private var showNowPlaying = false

    var body: some View {
        @Bindable var navigator = navigator
        TabView(selection: $navigator.tab) {
            Tab("Home", systemImage: "house", value: AppTab.home) {
                NavigationStack(path: $navigator.home) { HomeView().magpieRoutes() }
            }
            Tab("Library", systemImage: "square.stack", value: AppTab.library) {
                NavigationStack(path: $navigator.library) { LibraryView().magpieRoutes() }
            }
            Tab(value: AppTab.search, role: .search) {
                SearchView()
            }
        }
        .tabViewBottomAccessory(isEnabled: model.player.queue.current != nil || model.previewPlayer.isActive) {
            MiniPlayerAccessory { showNowPlaying = true }
        }
        .sheet(isPresented: $showNowPlaying) {
            NowPlayingView().environment(navigator)
                .immersiveArt(coverArtId: model.player.queue.current?.song.coverArtId)   // R13
                .findsKeepFlow(host: FindsLibraryMenuItem.nowPlaying)   // R18/R20: Keep from Now Playing's menus
        }
        .environment(navigator)
        .queueActionsPresenter()   // R12
        .findsKeepFlow(host: FindsLibraryMenuItem.main)   // R18/R20: Keep from a song's long-press menu
        .songActionsPresenter(navigator: navigator)   // round 14 A3: the outside songs' ⋯ menus
    }
}

/// The design-system mini player fed from `Player`. While a find that just became ready waits next in the queue
/// (D6), the accessory offers it instead: "<song> is ready", Play now.
private struct MiniPlayerAccessory: View {
    @Environment(AppModel.self) private var model
    let open: () -> Void

    var body: some View {
        let player = model.player
        if model.previewPlayer.isActive {
            PreviewMiniPlayerAccessory()   // round 14 A2: the preview playing, with Stop
        } else if let banner = model.visibleBanner {
            PlayNowBannerView(banner: banner, open: open)
        } else if let song = player.queue.current?.song {
            let preview = model.previewPlayer
            Artwork(song.coverArtId, side: 36) { image in
                // Round 14 A2: previews paused this song; Resume plays it on (nothing resumes it by itself).
                MiniPlayer(title: song.title, artist: song.artist, artwork: image, isPlaying: player.isPlaying,
                           onPlayPause: { preview.offersResume ? preview.resumeMain() : player.toggle() },
                           onNext: { player.next() }, onOpen: open, offersResume: preview.offersResume)
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
    /// R17: the banner's "Show request" opens the request's page over it.
    @State private var showsRequest = false
    private let themed = Themed()

    var body: some View {
        let p = themed.palette
        let player = model.player
        // The idle landing: the find itself is loaded and Play now plays it; nothing else to pause.
        let showsPause = !banner.idle && player.queue.current != nil
        let titles = VStack(alignment: .leading, spacing: 1) {
            Text(LandingCopy.title(banner.song)).font(.subheadline.weight(.semibold)).lineLimit(1)
            Text(LandingCopy.upNext).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        HStack(spacing: 4) {
            // V-fix: the title truncates; when even a short title wouldn't fit beside it, the record icon goes.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    // R16: the song's cover (it's in the library now: the P4 cache), the record symbol until then.
                    Artwork(banner.song.coverArtId, side: 30) { art in
                        if let art {
                            SleeveArt(image: art, side: 30)
                        } else {
                            Image(systemName: "record.circle").font(.title2).foregroundStyle(p.accentInkColor)
                        }
                    }
                    .frame(width: 30, height: 36)
                    .accessibilityHidden(true)
                    titles.frame(minWidth: 0, idealWidth: 96, maxWidth: .infinity, alignment: .leading)
                }
                titles.frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: Tokens.minHitSize)
            .contentShape(Rectangle())
            .onTapGesture(perform: open)
            if showsPause {
                Button { player.toggle() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.body)
                        .frame(width: Tokens.minHitSize, height: Tokens.minHitSize).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("play-now-banner-pause")
            }
            // Y7: the design system's filled capsule, not iOS's bordered style.
            CapsuleButton(LandingCopy.playNow, style: .fill) { model.playNow(banner) }
                .fixedSize()
            Button { model.dismissBanner() } label: {
                Image(systemName: "xmark").font(.footnote.weight(.semibold))
                    .frame(width: Tokens.minHitSize, height: Tokens.minHitSize).contentShape(Rectangle())
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
        .accessibilityAction(named: BannerCopy.showRequest) { showsRequest = true }
        .contextMenu {   // R17: back to its request (a tap still opens Now Playing, B-M4)
            Button(BannerCopy.showRequest, systemImage: "tray.and.arrow.down") { showsRequest = true }
        }
        .sheet(isPresented: $showsRequest) {
            NavigationStack {
                RequestDetailView(requestId: banner.request)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) { Button("Done") { showsRequest = false } }
                    }
                    .magpieRoutes()
            }
        }
        .accessibilityIdentifier("play-now-banner")
    }
}

enum BannerCopy {
    static let showRequest = "Show request"
}
