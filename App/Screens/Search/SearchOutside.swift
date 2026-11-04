import MagpieCore
import Search
import SwiftUI

/// Round 14 A5: Search's words for the band's paging and the songs it finds that you already have (§5 voice; the
/// glossary's "your library"). Never a service's name.
enum SearchCopy {
    static let inYourLibrary = "In your library"
    static func more(_ kind: OutsideKind) -> String {
        switch kind {
        case .songs: "More songs"
        case .artists: "More artists"
        case .albums: "More albums"
        }
    }
}

extension View {
    /// Round 14: the slot on an outside song row where its preview goes. A3 fills it (matching the song to the
    /// artist's previews and the ⋯ menu); until then the row is as it was.
    func searchPreviewSlot(_ recording: ExternalRecording) -> some View {
        modifier(SearchPreviewSlot(recording: recording))
    }
}

/// A3's hook: an outside song in Search (it carries its recording MBID, title, artist and release).
struct SearchPreviewSlot: ViewModifier {
    let recording: ExternalRecording

    func body(content: Content) -> some View { content }
}
