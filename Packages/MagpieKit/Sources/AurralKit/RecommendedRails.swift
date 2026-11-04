import Foundation
import MagpieCore

/// Round 14 A4 (D92): the Recommended page's and Home's rails, grouped as Aurral 2.13's own web page groups them
/// (`frontend/src/pages/recommendedRails.ts`), from one `GET /api/discover` answer:
/// - **Top pick**: the first artist;
/// - **New this week**: first found in the last 7 days;
/// - **Because you like X**: up to `seedRows` (3) seeds, each with at least 4 direct picks, in the order Aurral names
///   its seeds (`basedOn`), then in the order they first appear;
/// - **Close to home**: depth 1 artists no rail above showed;
/// - **Further out**: depth 2 or more;
/// - **All**: everything, sortable by rank, name or first seen.
/// Artists the owner said Not for me (`hidden`, by `key`) leave every rail at once.
public struct RecommendedRails: Sendable, Equatable {
    public struct SeedRail: Sendable, Equatable {
        public var seed: String
        public var artists: [AurralRecommendedArtist]
    }

    public enum Sort: String, Sendable, CaseIterable { case rank, name, firstSeen }

    public var topPick: AurralRecommendedArtist?
    public var newThisWeek: [AurralRecommendedArtist]
    public var becauseYouLike: [SeedRail]
    public var closeToHome: [AurralRecommendedArtist]
    public var furtherOut: [AurralRecommendedArtist]
    public var all: [AurralRecommendedArtist]

    public static let minimumSeedPicks = 4
    public static let newWindow: TimeInterval = 7 * 86_400

    public init(_ recommendations: AurralRecommendations, now: Date, hidden: Set<String> = [], seedRows: Int = 3) {
        let all = recommendations.artists.filter { !hidden.contains(Self.key($0)) }
        self.all = all
        topPick = all.first
        newThisWeek = all.dropFirst().filter { a in
            a.firstDiscoveredAt.map { now.timeIntervalSince($0) <= Self.newWindow && $0 <= now.addingTimeInterval(86_400) } ?? false
        }
        // Seeds: Aurral's named ones first, then any other a pick names, in first-seen order.
        var seeds: [String] = []
        for seed in recommendations.basedOn.map(\.name) + all.flatMap(Self.seeds) where !seeds.contains(seed) {
            seeds.append(seed)
        }
        var rails: [SeedRail] = []
        for seed in seeds where rails.count < max(0, min(seedRows, 3)) {
            let picks = all.dropFirst().filter { !$0.isFurtherOut && Self.seeds($0).contains(seed) }
            if picks.count >= Self.minimumSeedPicks { rails.append(SeedRail(seed: seed, artists: picks)) }
        }
        becauseYouLike = rails
        furtherOut = all.dropFirst().filter(\.isFurtherOut)
        var shown = Set(newThisWeek.map(Self.key) + rails.flatMap { $0.artists.map(Self.key) })
        if let topPick { shown.insert(Self.key(topPick)) }
        closeToHome = all.filter { !$0.isFurtherOut && !shown.contains(Self.key($0)) }
    }

    /// The artist's seeds: Aurral's supporting seeds, else its source artists.
    static func seeds(_ a: AurralRecommendedArtist) -> [String] {
        a.supportingSeeds.isEmpty ? a.sourceArtists : a.supportingSeeds
    }

    /// One artist's identity for hiding: its MBID, else its folded name.
    public static func key(_ a: AurralRecommendedArtist) -> String {
        a.mbid.map { "mbid:" + $0.rawValue } ?? "name:" + DiscoverRules.normalised(a.name).lowercased()
    }

    /// All, in the chosen order: Aurral's rank, A–Z, or newest found first.
    public func sorted(_ sort: Sort) -> [AurralRecommendedArtist] {
        switch sort {
        case .rank: all
        case .name: all.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .firstSeen:
            all.enumerated().sorted { a, b in
                let x = a.element.firstDiscoveredAt ?? .distantPast, y = b.element.firstDiscoveredAt ?? .distantPast
                return x != y ? x > y : a.offset < b.offset
            }.map(\.element)
        }
    }

    /// A card's line, as Aurral's page writes it: "Like X, Y" close to home, "Via X" further out, else the first genre.
    public static func subtitle(_ a: AurralRecommendedArtist) -> String? {
        let seeds = seeds(a)
        if !seeds.isEmpty {
            return a.isFurtherOut ? "Via \(seeds[0])" : "Like " + seeds.prefix(2).joined(separator: ", ")
        }
        guard let tag = a.tags.first, let first = tag.first else { return nil }
        return first.uppercased() + tag.dropFirst()
    }
}
