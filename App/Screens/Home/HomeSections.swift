import DesignSystem
import MagpieCore
import NavidromeKit
import SwiftUI

// Round 14 A6: the Spotify-style Home's own pieces: the greeting, the filter chips, the quick grid and the provided
// tiles, plus the pure rules behind them (tested in Round14HomeTests).

/// Widths and rows for Home's shelves.
enum HomeShelfLayout {
    /// A card's width for the owner's size (a tile widens further at accessibility sizes, D15).
    static func width(_ size: HomeCardSize) -> CGFloat {
        switch size {
        case .small: 110
        case .medium: 140
        case .large: 180
        }
    }

    struct Row: Equatable {
        var seed: String
        var items: [HomeShelf.Item]
    }

    /// Because you like: one row per seed artist, in the provider's order, at most `rows` (0–3). A tile without a
    /// seed is left out (it would have no title to sit under).
    static func becauseYouLikeRows(_ items: [HomeShelf.Item], rows: Int) -> [Row] {
        var result: [Row] = []
        for item in items {
            guard case .outside(let outside) = item, let seed = outside.group, !seed.isEmpty else { continue }
            if let index = result.firstIndex(where: { $0.seed == seed }) {
                result[index].items.append(item)
            } else if result.count < max(0, rows) {
                result.append(Row(seed: seed, items: [item]))
            }
        }
        return result
    }
}

extension HomeCopy {
    /// "Good morning" (5–11), "Good afternoon" (12–17), "Good evening" (otherwise).
    static func greeting(hour: Int) -> String {
        switch hour {
        case 5..<12: "Good morning"
        case 12..<18: "Good afternoon"
        default: "Good evening"
        }
    }

    /// A Because you like row's title.
    static func becauseYouLike(_ seed: String) -> String { "Because you like \(seed)" }

    /// A quick tile's line: the album's artist, or what kind of playlist it is.
    static func quickSubtitle(_ play: RecentPlay, isFlow: Bool) -> String {
        switch play.kind {
        case .album: play.subtitle ?? "Album"
        case .playlist: isFlow ? "Flow" : "Playlist"
        }
    }
}

/// The top of Home: "Good evening". Edit Home is the toolbar's button and the one at the bottom (fix round 1: no third).
struct HomeGreeting: View {
    private let themed = Themed()

    var body: some View {
        TimelineView(.everyMinute) { context in
            Text(HomeCopy.greeting(hour: Calendar.current.component(.hour, from: context.date)))
                .magpieDisplay(.title)
                .foregroundStyle(themed.palette.inkColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("home-greeting")
        }
        .padding(.horizontal, Tokens.Spacing.margin)
    }
}

/// All · Discover · Recommended · Your library (only the chips with something on Home).
struct HomeFilterChips: View {
    let chips: [HomeFilter]
    let picked: HomeFilter
    let pick: (HomeFilter) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Tokens.Spacing.s) {
                ForEach(chips, id: \.self) { chip in
                    FilterChip(chip.title, isSelected: chip == picked) { pick(chip) }
                        .accessibilityIdentifier("home-chip-\(chip.rawValue)")
                }
            }
            .padding(.horizontal, Tokens.Spacing.margin)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Filters")
    }
}

/// Up to 8 compact tiles, two to a row (one at accessibility sizes): one tap opens, a long press offers Play and
/// Shuffle.
struct QuickAccessGrid: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize
    let tiles: [RecentPlay]

    var body: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: Tokens.Spacing.s),
                            count: typeSize.isAccessibilitySize ? 1 : 2)
        LazyVGrid(columns: columns, spacing: Tokens.Spacing.s) {
            ForEach(Array(tiles.enumerated()), id: \.element.id) { index, play in
                NavigationLink(value: route(play)) {
                    Artwork(play.coverArtId, side: 56) { image in
                        CompactTile(title: play.title, subtitle: subtitle(play), artwork: image)
                    }
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button { Task { await start(play, shuffled: false) } } label: { Label("Play", systemImage: "play.fill") }
                    Button { Task { await start(play, shuffled: true) } } label: { Label("Shuffle", systemImage: "shuffle") }
                }
                // Fix round 1 (D15): the long press's actions straight from VoiceOver's actions rotor.
                .accessibilityAction(named: "Play") { Task { await start(play, shuffled: false) } }
                .accessibilityAction(named: "Shuffle") { Task { await start(play, shuffled: true) } }
                .accessibilityIdentifier("quick-\(index)")
            }
        }
        .padding(.horizontal, Tokens.Spacing.margin)
        .accessibilityIdentifier("home-quickAccess")
    }

    private func subtitle(_ play: RecentPlay) -> String {
        HomeCopy.quickSubtitle(play, isFlow: play.kind == .playlist && model.isDiscoverPlaylist(id: play.itemId))
    }

    private func route(_ play: RecentPlay) -> Route {
        switch play.kind {
        case .album: .album(id: play.itemId)
        case .playlist: .playlist(id: play.itemId)
        }
    }

    /// The long press's Play and Shuffle: the songs, then the queue (it heads the grid again).
    private func start(_ play: RecentPlay, shuffled: Bool) async {
        let collection: CollectionRef = play.kind == .album ? .album(play.itemId) : .playlist(play.itemId)
        guard let songs = try? await model.songs(of: collection), !songs.isEmpty else {
            model.libraryEdits.notify(QueueCopy.couldntLoad, symbol: "exclamationmark.triangle")
            return
        }
        model.noteRecentlyPlayed(play)
        shuffled ? model.shuffle(songs) : model.play(songs, startAt: 0)
    }
}

/// A provided tile: an artist as a circle, anything else as a card (large at the large size). It opens where the
/// provider says; with nowhere to go it is plain.
struct OutsideTile: View {
    @Environment(AppModel.self) private var model
    let item: HomeOutsideItem
    let section: HomeSection
    let size: HomeCardSize
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let route = model.homeAurralShelves.route(for: item, in: section) {
                NavigationLink(value: route) { tile }.buttonStyle(.plain)
            } else {
                tile
            }
        }
        .task(id: item.artworkKey) {
            image = item.artworkKey == nil ? nil
                : await model.homeAurralShelves.artwork(for: item, side: HomeShelfLayout.width(size))
        }
    }

    @ViewBuilder private var tile: some View {
        let artwork = image.map { Image(uiImage: $0) }
        let width = HomeShelfLayout.width(size)
        switch item.kind {
        case .artist:
            ArtistCircle(title: item.title, subtitle: item.subtitle, artwork: artwork, width: width - 10)
        default:
            if size == .large {
                LargeCard(title: item.title, subtitle: item.subtitle, artwork: artwork, width: width + 40)
            } else {
                AlbumTile(title: item.title, subtitle: item.subtitle ?? "", artwork: artwork, width: width)
            }
        }
    }
}
