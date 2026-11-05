import DesignSystem
import Playback
import SwiftUI
import UIKit

/// Round 14 A2 (D89): the preview controls screens use (A3–A5). Each renders nothing at all when previews can't work
/// (no Aurral, an Aurral that can't preview, offline): `AppModel.previewsAvailable`.

/// A song's preview button, fed from the preview player.
struct PreviewControl: View {
    @Environment(AppModel.self) private var model
    let item: PreviewItem

    var body: some View {
        if model.previewsAvailable {
            PreviewButton(status: PreviewCopy.status(model.previewPlayer.state(for: item), player: model.previewPlayer)) {
                model.togglePreview(item)
            }
        }
    }
}

/// A song from outside the library with its preview and the caller's ⋯ menu items.
struct PreviewSongRow<MenuItems: View>: View {
    @Environment(AppModel.self) private var model
    let item: PreviewItem
    var artwork: Image? = nil
    var inLibrary = false
    @ViewBuilder let menu: () -> MenuItems

    var body: some View {
        let status = model.previewsAvailable
            ? PreviewCopy.status(model.previewPlayer.state(for: item), player: model.previewPlayer) : nil
        PreviewRow(title: item.title, artist: item.artist, artwork: artwork, inLibrary: inLibrary, status: status,
                   onPreview: { model.togglePreview(item) }, menu: menu)
    }
}

/// "Play previews": the list in order, 30 seconds each. Hidden without previews, or when no song in the list has one.
struct PlayPreviewsButton: View {
    @Environment(AppModel.self) private var model
    let items: [PreviewItem]

    var body: some View {
        if model.previewsAvailable, items.contains(where: { $0.previewId != nil }) {
            CapsuleButton(PreviewCopy.playPreviews, symbol: "play.circle") { model.playPreviews(items) }
                .accessibilityIdentifier("play-previews")
        }
    }
}

/// The mini player while a preview plays (D86): the song, "Preview", the ring around Stop, Next in a list.
/// Round 15 C1 (owner item 4, D127): with the song's cover, the picture its row shows.
struct PreviewMiniPlayerAccessory: View {
    @Environment(AppModel.self) private var model
    /// The cover, and for which preview (a picture never shows on another song).
    @State private var picture: (itemId: String, image: UIImage)?

    var body: some View {
        let preview = model.previewPlayer
        if let item = preview.current {
            let hasNext = (preview.index ?? 0) + 1 < preview.items.count
            let shown = picture?.itemId == item.id ? picture?.image : nil
            PreviewMiniPlayer(title: item.title, artist: item.artist, artwork: shown.map { Image(uiImage: $0) },
                              status: PreviewCopy.status(preview.state(for: item), player: preview),
                              onStop: { preview.stop() }, onNext: hasNext ? { preview.next() } : nil)
                .artworkTestMarker("preview-mini-player-art", loaded: shown != nil)
                .task(id: "\(item.id)|\(item.artworkKey ?? "")") {
                    guard picture?.itemId != item.id, let found = await model.previewArtwork(item, side: 36) else { return }
                    // C1 review minor 1: a load cancelled by the next preview never overwrites that one's cover.
                    guard !Task.isCancelled else { return }
                    picture = (item.id, found)
                }
        }
    }
}

/// The words previews use (design language §5: about music, never a service); the button's own come from `PreviewStatus`.
enum PreviewCopy {
    static let noPreview = PreviewStatus.noPreview.label
    static let unavailable = PreviewStatus.unavailable.label
    static let playPreviews = "Play previews"

    static func label(for state: PreviewPlayer.ItemState) -> String { status(state, secondsLeft: 0).label }

    /// The design system's button status for a preview item's state.
    @MainActor static func status(_ state: PreviewPlayer.ItemState, player: PreviewPlayer) -> PreviewStatus {
        status(state, secondsLeft: player.remaining)
    }

    static func status(_ state: PreviewPlayer.ItemState, secondsLeft: Int) -> PreviewStatus {
        switch state {
        case .ready: .ready
        case .loading: .loading
        case .playing(let p), .paused(let p): .playing(progress: p, secondsLeft: secondsLeft)
        case .noPreview: .noPreview
        case .unavailable: .unavailable
        }
    }
}
