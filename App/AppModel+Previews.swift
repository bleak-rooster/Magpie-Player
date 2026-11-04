import AurralKit
import Foundation
import MagpieCore
import Observation
import Playback

/// Round 14 A2 (D85–D89): 30-second previews, through Aurral.
///
/// - Previews show only when they can work (owner answer 9): Aurral is signed in at an allowed address, it can preview
///   (2.13 with Discover or Trending, as last read from its bootstrap), and Magpie isn't offline. Otherwise no preview
///   control renders at all (`PreviewControl`, `PlayPreviewsButton`), and the calls below do nothing.
/// - Each play resolves the preview just before it plays, through `PreviewResolver` on the saved Aurral base (its one
///   address: M4), with no login. The signed link it pins is handed to the preview engine and never kept or logged; the
///   engine follows further redirects to https only (D88; the pin covers Aurral's own hop, not every hop after it).
extension AppModel {
    /// Preview controls may show.
    var previewsAvailable: Bool {
        guard aurralSetUp, !isOffline, let connection = discover.connection, aurralAllows(connection.base) else { return false }
        let can = aurralCapabilities
        return can.artistPreview || can.trending || can.editorialPlaylists
    }

    /// A preview button: plays this song's preview alone, or stops it when it is the one previewing.
    func togglePreview(_ item: PreviewItem) {
        // Without previews, only Stop on the preview still playing gets through (never a new play that pauses the main
        // player for a lookup that can't work).
        guard previewsAvailable || (previewPlayer.isActive && previewPlayer.current?.id == item.id) else { return }
        previewPlayer.toggle(item)
    }

    /// Play previews: the list in order, 30 seconds each, from `startAt`.
    func playPreviews(_ items: [PreviewItem], startAt: Int = 0) {
        guard previewsAvailable else { return }
        previewPlayer.play(items, startAt: startAt)
    }

    /// An Aurral song (chart, Discover playlist, an artist's top songs) as a preview item. Its Deezer id keys it.
    func previewItem(for song: AurralSong) -> PreviewItem {
        let base = discover.connection?.base
        let key = song.key ?? song.preview?.trackId ?? "\(song.artistName)|\(song.trackName)"
        return PreviewItem(id: "aurral-\(key)", previewId: song.preview?.trackId, title: song.trackName,
                           artist: song.artistName, album: song.albumName,
                           artworkURL: base.flatMap { song.artwork?.url(on: $0) })
    }

    /// Resolves a preview through Aurral right now (D87): 404 is "No preview available"; a 5xx, a timeout, a refused
    /// redirect or no usable Aurral is "Preview unavailable right now".
    func lookUpPreview(_ previewId: String) async -> PreviewLookup {
        guard previewsAvailable, let base = discover.connection?.base, let preview = AurralPreview(trackId: previewId) else {
            return .unavailable
        }
        do {
            switch try await PreviewResolver(base: base, transport: previewTransport).resolve(preview) {
            case .playable(let url): return .playable(url)
            case .noPreview: return .noPreview
            }
        } catch {
            return .unavailable
        }
    }

    /// Hooks the preview player to Aurral, and stops a preview when previews can no longer work (Aurral signed out,
    /// offline, a capability gone).
    func wirePreviews() {
        previewPlayer.lookup = { [weak self] id in await self?.lookUpPreview(id) ?? .unavailable }
        // The sleep timer firing stops a preview too (it pauses the main player, already paused under a preview).
        sleepTimer.onFire = { [weak self] in self?.previewPlayer.stop() }
        previewWatch = Task { [weak self] in
            let available = Observations { @MainActor [weak self] in self?.previewsAvailable ?? false }
            for await on in available where !on {
                guard let self else { return }
                if self.previewPlayer.isActive { self.previewPlayer.stop() }
            }
        }
    }
}
