import MagpieCore
import SwiftUI
import UIKit

/// One tile on a provided Home shelf (Recommended for you, New this week, Because you like, More playlists for you,
/// Close to home, Further out, Trending, Charts by genre). Plain values only, so Home's saved shelves can hold it: no
/// URL (the provider turns `artworkKey` into a picture).
struct HomeOutsideItem: Identifiable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable { case artist, song, album, playlist, genre }

    var kind: Kind
    /// The provider's stable id (an MBID, a chart or playlist id).
    var key: String
    var title: String
    var subtitle: String?
    /// The provider's handle for the picture, resolved by `HomeAurralShelves.artwork(for:side:)`.
    var artworkKey: String?
    /// Because you like: the seed artist; each seed is one row.
    var group: String?

    var id: String { "\(kind.rawValue)-\(key)" }
}

/// Round 14 A6 (D109): where Home's provided sections come from. Home never talks to Aurral itself: round 14 A4
/// supplies the real provider (`AppModel.homeAurralShelves`); until then `NoHomeAurralShelves` offers nothing and
/// those sections stay hidden.
///
/// The contract (fix round 1, I2), so Home never waits on Aurral and never pops in (round 13):
/// - **Observable.** `availableSections` is read while Home draws; a change redraws Home and reads what it needs.
/// - **`availableSections`** names the sections it can fill. Answer synchronously, from what is known now (saved
///   feature detection); never wait for the network to answer it. A section shows on Home while Aurral is set up and
///   either this names it or a shelf of it was saved last time, so a slow start never hides a saved shelf.
/// - **`items`** reads one section's tiles. Throw when it couldn't (Aurral down, slow, not ready): Home keeps the
///   last good copy and retries; it says "Couldn't load" only when there was none. Return `[]` only when the section
///   really is empty: that removes it. Home asks only for sections named in `availableSections` (a saved one not
///   named yet counts as not loaded and is retried).
/// - **`route`** says where a tile goes (nil: the tile is plain); **`artwork`** gives its picture from `artworkKey`.
@MainActor protocol HomeAurralShelves: AnyObject, Observable {
    var availableSections: Set<HomeSection> { get }
    func items(for section: HomeSection, limit: Int) async throws -> [HomeOutsideItem]
    func route(for item: HomeOutsideItem, in section: HomeSection) -> Route?
    func artwork(for item: HomeOutsideItem, side: CGFloat) async -> UIImage?
}

/// A provided section the provider hasn't named yet (it is shown from its saved shelf): not loaded, retried.
struct HomeSectionNotOffered: Error {}

/// No provider yet: every provided section is hidden.
@MainActor @Observable final class NoHomeAurralShelves: HomeAurralShelves {
    var availableSections: Set<HomeSection> { [] }
    func items(for section: HomeSection, limit: Int) async throws -> [HomeOutsideItem] { [] }
    func route(for item: HomeOutsideItem, in section: HomeSection) -> Route? { nil }
    func artwork(for item: HomeOutsideItem, side: CGFloat) async -> UIImage? { nil }
}

extension AppModel {
    /// The provided sections Home may show: only while Aurral is set up; those the provider names, and those with a
    /// shelf saved or on screen (fix round 1, I2: shown at launch before the provider answers).
    var homeOutsideSections: Set<HomeSection> {
        guard aurralSetUp else { return [] }
        let saved = Set(homeFeed.load?.found.keys.filter(\.isProvided) ?? [])
        return homeAurralShelves.availableSections.filter(\.isProvided).union(saved)
    }
}
