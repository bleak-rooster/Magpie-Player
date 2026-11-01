import DesignSystem
import MagpieCore
import NavidromeKit
import Observation
import Playback
import SwiftUI

// Round 11 R12: swipe actions on song and collection rows, the toast that confirms them, the collection popup
// ("In order" / "Shuffled") and "Ask before replacing the queue". CarPlay plays through the player directly, so none
// of this reaches the car (D12).

/// Where a swipe puts songs in the queue.
enum QueuePlacement: Equatable { case next, end }

/// An album, playlist or artist a row stands for.
enum CollectionRef: Hashable {
    case album(String)
    case playlist(String)
    case artist(String)
    /// A playlist or an artist as downloaded (Library › Downloads): only their songs on the phone.
    case downloadedPlaylist(String)
    case downloadedArtist(String)
}

enum QueueCopy {
    static let playingNext = "Playing next"
    static let addedToQueue = "Added to queue"
    static let replaceTitle = "Replace your queue?"
    static let replace = "Replace"
    static let playNext = "Play next"
    static let addToQueue = "Add to queue"
    static let inOrder = "In order"
    static let shuffled = "Shuffled"
    static let couldntLoad = "Couldn't get those songs. Try again in a moment."

    /// "Your queue has 12 songs."
    static func replaceMessage(_ count: Int) -> String { "Your queue has \(count) songs." }

    static func toast(_ placement: QueuePlacement) -> String { placement == .next ? playingNext : addedToQueue }

    /// The popup's title for a collection swipe.
    static func collectionTitle(_ placement: QueuePlacement) -> String { placement == .next ? "Play next" : "Add to queue" }

    /// A swipe action's button and picker title (sentence case, the glossary's words).
    static func title(_ action: SwipeAction, favourite: Bool = false) -> String {
        switch action {
        case .playNext: "Play next"
        case .addToQueue: "Add to queue"
        case .addToPlaylist: "Add to playlist…"
        case .download: "Download"
        case .favourite: favourite ? "Unfavourite" : "Favourite"
        case .none: "None"
        }
    }

    static func symbol(_ action: SwipeAction, favourite: Bool = false) -> String {
        switch action {
        case .playNext: "text.line.first.and.arrowtriangle.forward"
        case .addToQueue: "text.line.last.and.arrowtriangle.forward"
        case .addToPlaylist: "text.badge.plus"
        case .download: "arrow.down.to.line"
        case .favourite: favourite ? "star.slash" : "star"
        case .none: "nosign"
        }
    }
}

/// Which buttons a row's swipes show, and whether a full swipe fires the outermost one (R12, appraisal §4: a
/// destructive action keeps its trailing place, both stay on that edge, and that edge never full-swipes).
struct SwipeLayout: Equatable {
    enum Item: Equatable {
        case action(SwipeAction)
        /// The row's own destructive action (Remove from playlist, Remove download, Not for me).
        case destructive(String)
    }

    /// Outermost first.
    var leading: [Item]
    var trailing: [Item]
    var leadingFullSwipe: Bool
    var trailingFullSwipe: Bool

    static func song(right: SwipeAction, left: SwipeAction, destructive: String? = nil) -> SwipeLayout {
        SwipeLayout(leading: right == .none ? [] : [.action(right)],
                    trailing: (destructive.map { [Item.destructive($0)] } ?? []) + (left == .none ? [] : [.action(left)]),
                    leadingFullSwipe: true, trailingFullSwipe: destructive == nil)
    }

    /// Albums, playlists and artists: right = Add to queue, left = Play next, then the In order / Shuffled popup.
    static let collection = SwipeLayout(leading: [.action(.addToQueue)], trailing: [.action(.playNext)],
                                        leadingFullSwipe: true, trailingFullSwipe: true)
}

/// The R12 state screens share: the toast, the Add to playlist sheet asked for by a swipe, the queue-replace
/// question and the collection popup. One object, so `AppModel` holds a single property for it.
@MainActor @Observable final class QueueActions {
    struct Toast: Equatable, Identifiable {
        let id: Int
        let text: String
        let symbol: String
    }

    /// Tapping to play would replace a queue of `queueCount` songs.
    struct PendingReplace: Identifiable {
        let id = UUID()
        let songs: [Song]
        let startAt: Int
        let queueCount: Int
    }

    /// A collection swiped: asks In order or Shuffled.
    struct PendingCollection: Identifiable {
        let id = UUID()
        let collection: CollectionRef
        let placement: QueuePlacement
    }

    struct PlaylistRequest: Identifiable {
        let id = UUID()
        let songIds: [String]
    }

    var toast: Toast?
    var addingToPlaylist: PlaylistRequest?
    var pendingReplace: PendingReplace?
    var pendingCollection: PendingCollection?
    @ObservationIgnored private var nextToast = 0

    /// Shows `text` briefly and has VoiceOver say it.
    func show(_ text: String, symbol: String) {
        nextToast += 1
        toast = Toast(id: nextToast, text: text, symbol: symbol)
        AccessibilityNotification.Announcement(text).post()
    }
}

extension AppModel {
    /// The songs in the queue now: what's played, the current song, Up next and the rest.
    var queuedSongCount: Int { player.queue.main.count + player.queue.upNext.count }

    /// Tap to play (R12): replaces the queue, unless "Ask before replacing the queue" is on and the queue holds more
    /// than one song; then it asks first (Replace / Play next / Cancel).
    func play(_ songs: [Song], startAt: Int) {
        guard !songs.isEmpty else { return }
        if preferences.playback.askBeforeReplacingQueue, queuedSongCount > 1 {
            queueActions.pendingReplace = .init(songs: songs, startAt: startAt, queueCount: queuedSongCount)
            return
        }
        player.play(songs, startAt: startAt)
    }

    func shuffle(_ songs: [Song]) {
        play(songs.shuffled(), startAt: 0)
    }

    enum ReplaceChoice { case replace, playNext }

    /// The answer to "Replace your queue?". Play next puts the tapped song and what follows it ahead of the rest.
    func answer(_ pending: QueueActions.PendingReplace, _ choice: ReplaceChoice) {
        queueActions.pendingReplace = nil
        switch choice {
        case .replace: player.play(pending.songs, startAt: pending.startAt)
        case .playNext:
            let from = min(max(pending.startAt, 0), pending.songs.count - 1)
            place(Array(pending.songs[from...]), .next)
        }
    }

    /// Play next or Add to queue, with the toast.
    func place(_ songs: [Song], _ placement: QueuePlacement) {
        guard !songs.isEmpty else { return }
        placement == .next ? player.playNext(songs) : player.addToEnd(songs)
        queueActions.show(QueueCopy.toast(placement),
                          symbol: QueueCopy.symbol(placement == .next ? .playNext : .addToQueue))
    }

    /// A song row's swipe.
    func performSwipe(_ action: SwipeAction, on song: Song) {
        switch action {
        case .playNext: place([song], .next)
        case .addToQueue: place([song], .end)
        case .addToPlaylist: queueActions.addingToPlaylist = .init(songIds: [song.id])
        case .download:
            download([song], reason: .song)
            queueActions.show("Downloading", symbol: "arrow.down.to.line")
        case .favourite:
            let on = !isFavourite(.song(song.id))
            queueActions.show(on ? "Added to favourites" : "Removed from favourites", symbol: on ? "star.fill" : "star")
            Task { await setFavourite(.song(song.id), on) }
        case .none: break
        }
    }

    /// The songs of a collection, in order (an artist: every album in the artist page's order). Offline, or for a
    /// downloaded playlist, what's on the phone.
    func songs(of collection: CollectionRef) async throws -> [Song] {
        let local: Bool = switch collection {
        case .album(let id), .artist(let id): isOffline || OfflineCatalog.isLocalId(id)
        case .playlist: isOffline
        case .downloadedPlaylist, .downloadedArtist: true
        }
        if local {
            let catalog = await offlineCatalog
            switch collection {
            case .album(let id): return catalog.album(id: id)?.songs ?? []
            case .artist(let id), .downloadedArtist(let id): return catalog.albums(byArtist: id).flatMap { $0.songs ?? [] }
            case .playlist(let id), .downloadedPlaylist(let id): return catalog.songs(inPlaylist: id)
            }
        }
        switch collection {
        case .album(let id): return try await request { try await $0.album(id: id).songs ?? [] }
        case .playlist(let id), .downloadedPlaylist(let id): return try await request { try await $0.playlist(id: id).1 }
        case .downloadedArtist: return []   // read above
        case .artist(let id):
            return try await request { client in
                let ids = try await client.artist(id: id).1.map(\.id)
                return try await withThrowingTaskGroup(of: (Int, [Song]).self) { group in
                    for (i, id) in ids.enumerated() { group.addTask { (i, try await client.album(id: id).songs ?? []) } }
                    var byIndex: [Int: [Song]] = [:]
                    for try await (i, songs) in group { byIndex[i] = songs }
                    return ids.indices.flatMap { byIndex[$0] ?? [] }
                }
            }
        }
    }

    /// The collection popup's answer: the collection's songs, in order or shuffled, next or at the end.
    func queue(_ collection: CollectionRef, _ placement: QueuePlacement, shuffled: Bool) async {
        do {
            let songs = try await songs(of: collection)
            guard !songs.isEmpty else { return }
            place(shuffled ? songs.shuffled() : songs, placement)
        } catch {
            queueActions.show(QueueCopy.couldntLoad, symbol: "exclamationmark.triangle")
        }
    }
}

// MARK: - Rows

/// A row's own destructive swipe (it keeps its trailing place; R12).
struct RowDestructiveAction {
    let title: String
    let symbol: String
    let action: () -> Void
}

/// Whether the row sits in a `List` (the system's swipe actions) or a scroll view's stack (Magpie's own swipe, with
/// the same buttons, full swipe and VoiceOver actions).
enum SwipeHost { case list, stack }

extension View {
    /// R12 on a song row: the user's swipe right and swipe left actions, plus the row's own destructive one if any.
    func songSwipeActions(_ song: Song, in host: SwipeHost, destructive: RowDestructiveAction? = nil) -> some View {
        modifier(SongSwipeModifier(song: song, host: host, destructive: destructive))
    }

    /// R12 on an album, playlist or artist list row: right = Add to queue, left = Play next, then In order or Shuffled.
    func collectionSwipeActions(_ collection: CollectionRef, in host: SwipeHost) -> some View {
        modifier(CollectionSwipeModifier(collection: collection, host: host))
    }

    /// Shows R12's toast, the Add to playlist sheet, the replace question and the collection popup. Once, at the root.
    func queueActionsPresenter() -> some View { modifier(QueueActionsPresenter()) }
}

/// One swipe button as drawn.
struct SwipeButtonModel: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let tint: Color
    let action: () -> Void
}

private struct SongSwipeModifier: ViewModifier {
    @Environment(AppModel.self) private var model
    let song: Song
    let host: SwipeHost
    let destructive: RowDestructiveAction?

    func body(content: Content) -> some View {
        let prefs = model.preferences.playback
        let layout = SwipeLayout.song(right: prefs.swipeRight, left: prefs.swipeLeft, destructive: destructive?.title)
        content.modifier(SwipeRenderer(leading: layout.leading.map(button), trailing: layout.trailing.map(button),
                                       leadingFull: layout.leadingFullSwipe, trailingFull: layout.trailingFullSwipe,
                                       host: host))
    }

    private func button(_ item: SwipeLayout.Item) -> SwipeButtonModel {
        switch item {
        case .destructive(let title):
            return SwipeButtonModel(id: title, title: title, symbol: destructive?.symbol ?? "trash", tint: .red) {
                destructive?.action()
            }
        case .action(let action):
            let favourite = action == .favourite && model.isFavourite(.song(song.id))
            return SwipeButtonModel(id: QueueCopy.title(action), title: QueueCopy.title(action, favourite: favourite),
                                    symbol: QueueCopy.symbol(action, favourite: favourite), tint: Self.tint(action)) {
                model.performSwipe(action, on: song)
            }
        }
    }

    static func tint(_ action: SwipeAction) -> Color {
        switch action {
        case .playNext: .indigo
        case .addToQueue: .orange
        case .addToPlaylist: .teal
        case .download: .blue
        case .favourite: .yellow
        case .none: .gray
        }
    }
}

private struct CollectionSwipeModifier: ViewModifier {
    @Environment(AppModel.self) private var model
    let collection: CollectionRef
    let host: SwipeHost

    func body(content: Content) -> some View {
        let layout = SwipeLayout.collection
        content.modifier(SwipeRenderer(leading: layout.leading.map(button), trailing: layout.trailing.map(button),
                                       leadingFull: layout.leadingFullSwipe, trailingFull: layout.trailingFullSwipe,
                                       host: host))
    }

    private func button(_ item: SwipeLayout.Item) -> SwipeButtonModel {
        guard case .action(let action) = item else { preconditionFailure("collections have no destructive swipe") }
        let placement: QueuePlacement = action == .playNext ? .next : .end
        return SwipeButtonModel(id: QueueCopy.title(action), title: QueueCopy.title(action), symbol: QueueCopy.symbol(action),
                                tint: SongSwipeModifier.tint(action)) {
            model.queueActions.pendingCollection = .init(collection: collection, placement: placement)
        }
    }
}

/// Draws the swipes: the system's in a `List`, Magpie's own in a stack. Either way VoiceOver gets each as an action.
private struct SwipeRenderer: ViewModifier {
    let leading: [SwipeButtonModel]
    let trailing: [SwipeButtonModel]
    let leadingFull: Bool
    let trailingFull: Bool
    let host: SwipeHost

    func body(content: Content) -> some View {
        switch host {
        case .list:
            content
                .swipeActions(edge: .leading, allowsFullSwipe: leadingFull) {
                    ForEach(leading) { b in Button(b.title, systemImage: b.symbol, action: b.action).tint(b.tint) }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: trailingFull) {
                    ForEach(trailing) { b in Button(b.title, systemImage: b.symbol, action: b.action).tint(b.tint) }
                }
        case .stack:
            content
                .modifier(StackSwipe(leading: leading, trailing: trailing, leadingFull: leadingFull, trailingFull: trailingFull))
                .accessibilityActions {
                    ForEach(leading + trailing) { b in Button(b.title, action: b.action) }
                }
        }
    }
}

// MARK: - Presenter

private struct QueueActionsPresenter: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let themed = Themed()

    func body(content: Content) -> some View {
        let actions = model.queueActions
        content
            .overlay(alignment: .top) {
                if let toast = actions.toast {
                    Label(toast.text, systemImage: toast.symbol)
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, Tokens.Spacing.l).padding(.vertical, Tokens.Spacing.s)
                        .background(themed.palette.solidSurfaceColor, in: Capsule())
                        .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
                        .padding(.top, Tokens.Spacing.s)
                        .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                        .accessibilityHidden(true)   // announced when shown
                        .accessibilityIdentifier("queue-toast")
                        .task(id: toast.id) {
                            try? await Task.sleep(for: .seconds(1.5))
                            if actions.toast?.id == toast.id { withAnimation { actions.toast = nil } }
                        }
                }
            }
            .animation(reduceMotion ? nil : .spring(duration: 0.3), value: actions.toast)
            .sheet(item: Binding(get: { actions.addingToPlaylist }, set: { actions.addingToPlaylist = $0 })) { request in
                AddToPlaylistSheet(songIds: request.songIds)
            }
            .confirmationDialog(QueueCopy.replaceTitle,
                                isPresented: Binding(get: { actions.pendingReplace != nil },
                                                     set: { if !$0 { actions.pendingReplace = nil } }),
                                titleVisibility: .visible, presenting: actions.pendingReplace) { pending in
                Button(QueueCopy.replace, role: .destructive) { model.answer(pending, .replace) }
                Button(QueueCopy.playNext) { model.answer(pending, .playNext) }
                Button("Cancel", role: .cancel) {}
            } message: { pending in
                Text(QueueCopy.replaceMessage(pending.queueCount))
            }
            .confirmationDialog(actions.pendingCollection.map { QueueCopy.collectionTitle($0.placement) } ?? "",
                                isPresented: Binding(get: { actions.pendingCollection != nil },
                                                     set: { if !$0 { actions.pendingCollection = nil } }),
                                titleVisibility: .visible, presenting: actions.pendingCollection) { pending in
                Button(QueueCopy.inOrder) { Task { await model.queue(pending.collection, pending.placement, shuffled: false) } }
                Button(QueueCopy.shuffled) { Task { await model.queue(pending.collection, pending.placement, shuffled: true) } }
                Button("Cancel", role: .cancel) {}
            }
    }
}
