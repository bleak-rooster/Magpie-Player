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
/// those sections stay hidden. A provider:
/// - names the sections it can fill now (`availableSections`); one not named is hidden on Home, never broken;
/// - reads one section's tiles (`items`), throwing when it couldn't. Home's feed reads each section on its own,
///   keeps the last good copy (saved for launch) when a read fails, and never waits on it (round 13);
/// - says where a tile goes (`route`) and gives its picture (`artwork`).
@MainActor protocol HomeAurralShelves: AnyObject {
    var availableSections: Set<HomeSection> { get }
    func items(for section: HomeSection, limit: Int) async throws -> [HomeOutsideItem]
    func route(for item: HomeOutsideItem, in section: HomeSection) -> Route?
    func artwork(for item: HomeOutsideItem, side: CGFloat) async -> UIImage?
}

/// No provider yet: every provided section is hidden.
@MainActor final class NoHomeAurralShelves: HomeAurralShelves {
    var availableSections: Set<HomeSection> { [] }
    func items(for section: HomeSection, limit: Int) async throws -> [HomeOutsideItem] { [] }
    func route(for item: HomeOutsideItem, in section: HomeSection) -> Route? { nil }
    func artwork(for item: HomeOutsideItem, side: CGFloat) async -> UIImage? { nil }
}

extension AppModel {
    /// The provided sections Home may show: only while Aurral is set up, and only those the provider offers.
    var homeOutsideSections: Set<HomeSection> {
        aurralSetUp ? homeAurralShelves.availableSections.filter(\.isProvided) : []
    }
}
