import DesignSystem
import MagpieCore
import Search
import SwiftUI

/// Round 14 A5: Search's words for the band's paging and the songs it finds that you already have (§5 voice; the
/// glossary's "your library"). Never a service's name.
enum SearchCopy {
    static let inYourLibrary = "In your library"
    static let couldNotPlay = "Couldn\u{2019}t play this. Try again"
    static let couldNotLoadMore = "Couldn\u{2019}t load more. Try again"

    /// A kind's More. Songs with no rows yet (fix round 1, I2): the next albums are still to be looked through.
    static func more(_ kind: OutsideKind, hasRows: Bool = true) -> String {
        switch kind {
        case .songs: hasRows ? "More songs" : "Look for songs on more albums"
        case .artists: "More artists"
        case .albums: "More albums"
        }
    }
}

/// Which kinds of the "Not in your library" band show.
enum SearchBand {
    /// A kind shows with rows, or (fix round 1, I2) once the search is done with none yet but more to look through,
    /// so its More is never out of reach.
    static func shows(_ kind: OutsideKind, in sections: SearchSections, done: Bool = true) -> Bool {
        let band = sections.notYet
        let hasRows = switch kind {
        case .songs: !band.songs.isEmpty
        case .artists: !band.artists.isEmpty
        case .albums: !band.albums.isEmpty
        }
        return hasRows || (done && sections.hasMoreOutside(kind))
    }

    static func hasRows(_ kind: OutsideKind, in sections: SearchSections) -> Bool {
        shows(kind, in: sections, done: false)
    }
}

/// Round 14 (D98): the end of one kind in the band: More (a tap, never on scroll: an outside page can mean MusicBrainz
/// reads), a spinner while it loads, or Try again after a failure.
struct OutsideMoreFooter: View {
    let model: SearchModel
    let kind: OutsideKind
    let sections: SearchSections
    private let themed = Themed()

    var body: some View {
        if model.phase == .done, sections.hasMoreOutside(kind) {
            switch model.outsideMoreState(kind) {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: Tokens.minHitSize)
                    .accessibilityLabel("Loading more")
                    .accessibilityIdentifier("search-notyet-more-\(kind.rawValue)")
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            case .idle, .failed:
                let failed = model.outsideMoreState(kind) == .failed
                Button { model.loadMoreOutside(kind) } label: {
                    Label(failed ? SearchCopy.couldNotLoadMore
                                 : SearchCopy.more(kind, hasRows: SearchBand.hasRows(kind, in: sections)),
                          systemImage: failed ? "arrow.clockwise" : "chevron.down")
                        .font(.subheadline)
                        .frame(maxWidth: .infinity, minHeight: Tokens.minHitSize)
                }
                .buttonStyle(.plain)
                .foregroundStyle(themed.palette.ink2Color)
                .accessibilityIdentifier("search-notyet-more-\(kind.rawValue)")
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
        }
    }
}

/// Round 14 (D97): the library's rows are in; outside sources are still answering.
struct OutsidePendingRow: View {
    private let themed = Themed()

    var body: some View {
        HStack(spacing: Tokens.Spacing.s) {
            ProgressView()
            Text("Still looking outside your library\u{2026}").font(.footnote).foregroundStyle(themed.palette.ink2Color)
        }
        .frame(maxWidth: .infinity, minHeight: Tokens.minHitSize)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("search-outside-pending")
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }
}

/// Round 14 (D96): a song on an outside album's tracklist that the library has but its search didn't list: "In your
/// library", played from the library. Fix round 1 (M2): when the song can't be fetched, the row says so.
struct OwnedSongRow: View {
    @Environment(AppModel.self) private var app
    let item: OwnedOutsideSong
    let model: SearchModel
    let onPlay: () -> Void
    private let themed = Themed()

    var body: some View {
        let r = item.recording
        let failed = model.ownedFailed.contains(item.songId)
        Button {
            onPlay()
            let app = app, model = model, id = item.songId
            Task { await model.playOwned(id, lookup: { await app.librarySong(id: $0) }, play: { app.play([$0], startAt: 0) }) }
        } label: {
            HStack(spacing: Tokens.Spacing.m) {
                OutsideArtwork(model.outsideArt, key: .cover(releaseGroup: nil, release: r.releaseMBID)) { art in
                    SleeveArt(image: art, side: 48)
                }
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(r.title).font(.callout).lineLimit(1)
                    Text(r.artist).font(.footnote).foregroundStyle(themed.palette.ink2Color).lineLimit(1)
                    Label(failed ? SearchCopy.couldNotPlay : SearchCopy.inYourLibrary,
                          systemImage: failed ? "exclamationmark.circle" : "checkmark.circle")
                        .font(.caption).foregroundStyle(themed.palette.ink2Color)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, Tokens.Spacing.margin)
            .frame(minHeight: 60)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(r.title), \(r.artist)")
        .accessibilityValue(failed ? SearchCopy.couldNotPlay : SearchCopy.inYourLibrary)
        .accessibilityAddTraits(.isButton)
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
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
