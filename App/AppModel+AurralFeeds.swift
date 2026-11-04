import AurralKit
import CryptoKit
import Foundation
import MagpieCore
import Observation
import os
import UIKit

/// Round 14 A4 (D90): Trending, Recommended and the Discover playlists, each read on its own.
///
/// Round 13's Home lessons, applied to each:
/// - each loads and fails on its own; a slow or down Aurral never holds Home, the Library or another feed up;
/// - the last good copy is kept on disk, per Navidrome account and Aurral user (one small file, no secrets: no login,
///   no session, no signed link), shown at once at launch, and replaced only by a good read;
/// - a section Aurral leaves empty in one read keeps its last copy (`TrendingSnapshot.keeping`);
/// - never read: the page says "updating" rather than spinning or erroring.
/// It is also Home's provider (`HomeAurralShelves`, D109): the sections it names come from what Aurral can do, as last
/// read and saved, so a saved shelf shows at launch before Aurral answers.
@MainActor @Observable final class AurralFeeds: HomeAurralShelves {
    enum Feed: String, Codable, CaseIterable, Sendable { case trending, recommended, editorial }

    /// What this Aurral could give, as last read (saved, so Home names its sections at launch).
    struct Known: Codable, Equatable, Sendable {
        var trending = false
        var recommendations = false
        var editorial = false
    }

    @ObservationIgnored weak var model: AppModel?
    private(set) var trending: TrendingSnapshot?
    private(set) var recommended: RecommendedSnapshot?
    private(set) var editorial: EditorialSnapshot?
    /// Charts by genre, by Deezer genre id; `notReadyGenres`: Aurral said "not ready yet" (404).
    private(set) var genreCharts: [Int: [ChartSong]] = [:]
    private(set) var notReadyGenres: Set<Int> = []
    /// Not for me: hidden here at once, by `RecommendedRails.key`.
    private(set) var hidden: Set<String> = []
    /// Discover playlists (and charts) added with Add flow: the Deezer playlist id → the user's synced playlist id.
    private(set) var added: [String: String] = [:]
    private(set) var known = Known()
    /// The feeds whose last read failed (the page keeps its copy and says so quietly).
    private(set) var failed: Set<Feed> = []
    /// The feeds being read now.
    private(set) var reading: Set<Feed> = []

    /// This session's "In your library" lookups for chart and Discover playlist songs (a hit or a miss).
    @ObservationIgnored var lookups: [String: Song?] = [:]
    @ObservationIgnored private var readAt: [Feed: Date] = [:]
    @ObservationIgnored private var inFlight: [Feed: Task<Void, Never>] = [:]
    @ObservationIgnored private(set) var scope: String?
    @ObservationIgnored var now: () -> Date = Date.init

    /// How long a good read is used before reading again (Aurral itself refreshes charts every 5 hours).
    nonisolated static let freshFor: [Feed: TimeInterval] = [.trending: 30 * 60, .recommended: 10 * 60, .editorial: 30 * 60]

    init() {}

    // MARK: - Scope and disk

    /// The disk copy's name for this Navidrome account and Aurral user (a hash: never a server name or user name).
    nonisolated static func scope(navidrome: String, aurralBase: URL, aurralUser: String) -> String {
        var base = aurralBase.absoluteString.lowercased()
        while base.hasSuffix("/") { base.removeLast() }
        let digest = SHA256.hash(data: Data("\(navidrome)|\(base)|\(aurralUser.lowercased())".utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func directory(root: URL) -> URL { root.appending(path: "Magpie/Discover", directoryHint: .isDirectory) }

    private struct File: Codable {
        static let currentVersion = 1
        var version = File.currentVersion
        var known: Known
        var trending: TrendingSnapshot?
        var recommended: RecommendedSnapshot?
        var editorial: EditorialSnapshot?
        var genreCharts: [Int: [ChartSong]]
        var hidden: Set<String>
        var added: [String: String]
    }

    nonisolated static let maxBytes = 2 * 1024 * 1024

    private var fileURL: URL? {
        guard let scope, let root = model?.dataDirectory else { return nil }
        return Self.directory(root: root).appending(path: "\(scope).json")
    }

    /// Uses the copy saved for the signed-in Navidrome account and Aurral user (nothing without both); a change of
    /// account drops what was shown at once.
    func follow(scope newScope: String?) {
        guard newScope != scope else { return }
        clearMemory()
        scope = newScope
        guard let url = fileURL, let data = try? Data(contentsOf: url), data.count <= Self.maxBytes,
              let file = try? JSONDecoder().decode(File.self, from: data), file.version == File.currentVersion else { return }
        known = file.known
        trending = file.trending
        recommended = file.recommended
        editorial = file.editorial
        genreCharts = file.genreCharts.filter { !$0.value.isEmpty }
        hidden = file.hidden
        added = file.added
    }

    private func save() {
        guard let url = fileURL else { return }
        let file = File(known: known, trending: trending, recommended: recommended, editorial: editorial,
                        genreCharts: genreCharts, hidden: hidden, added: added)
        do {
            try AtomicFile.write(file, to: url)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var saved = url, directory = url.deletingLastPathComponent()
            try saved.setResourceValues(values)
            try directory.setResourceValues(values)
        } catch {
            Log.logger("discover").error("cannot save Discover's feeds: \(Log.category(of: error), privacy: .public)")
        }
    }

    private func clearMemory() {
        for task in inFlight.values { task.cancel() }
        inFlight = [:]
        readAt = [:]
        lookups = [:]
        trending = nil; recommended = nil; editorial = nil
        genreCharts = [:]; notReadyGenres = []; hidden = []; added = [:]; known = Known()
        failed = []; reading = []
    }

    /// Sign-out of Aurral or of the account: every copy goes (this phone keeps nothing of another user's).
    func forget() {
        clearMemory()
        scope = nil
        if let root = model?.dataDirectory { try? FileManager.default.removeItem(at: Self.directory(root: root)) }
    }

    /// What Aurral can do, as just read: saved for the next launch.
    func note(_ capabilities: AurralCapabilities) {
        let fresh = Known(trending: capabilities.trending, recommendations: capabilities.recommendations,
                          editorial: capabilities.editorialPlaylists)
        guard fresh != known else { return }
        known = fresh
        save()
    }

    /// What this Aurral can give now: as last read this session, else as saved.
    var can: Known {
        guard let model, model.aurralSetUp else { return Known() }
        guard model.discover.bootstrap != nil else { return known }
        let c = model.aurralCapabilities
        return Known(trending: c.trending, recommendations: c.recommendations, editorial: c.editorialPlaylists)
    }

    // MARK: - Reading

    /// Reads `feed` unless a good read is fresh (`force` reads anyway); one read per feed at a time. Offline, without
    /// Aurral, or when Aurral can't give it, nothing is asked.
    func refresh(_ feed: Feed, force: Bool = false) async {
        guard let model, model.aurralSetUp, !model.isOffline, model.aurralClient != nil, can.has(feed) else { return }
        if !force, let at = readAt[feed], now().timeIntervalSince(at) < Self.freshFor[feed] ?? 600, has(feed) { return }
        if let running = inFlight[feed] { await running.value; return }
        let task = Task<Void, Never> { [weak self] in await self?.read(feed) }
        inFlight[feed] = task
        await task.value
        if inFlight[feed] == task { inFlight[feed] = nil }
    }

    func has(_ feed: Feed) -> Bool {
        switch feed {
        case .trending: trending != nil
        case .recommended: recommended != nil
        case .editorial: editorial != nil
        }
    }

    private func read(_ feed: Feed) async {
        guard let model, let client = model.aurralClient else { return }
        let scopeAtStart = scope
        reading.insert(feed)
        defer { reading.remove(feed) }
        do {
            switch feed {
            case .trending:
                let fresh = try await model.loadTrending(client: client)
                guard scope == scopeAtStart, !Task.isCancelled else { return }
                trending = fresh.keeping(trending)
            case .recommended:
                let fresh = RecommendedSnapshot(try await client.recommendations(limit: 100))
                guard scope == scopeAtStart, !Task.isCancelled else { return }
                recommended = fresh
            case .editorial:
                let fresh = EditorialSnapshot(try await client.editorialShelf())
                guard scope == scopeAtStart, !Task.isCancelled else { return }
                editorial = fresh
            }
            readAt[feed] = now()
            failed.remove(feed)
            save()
        } catch {
            guard scope == scopeAtStart else { return }
            failed.insert(feed)   // the last copy stays
            model.noteAurralError(error)
        }
    }

    /// One genre's chart (50 songs): read when its page opens; nil while never read. A 404 is "not ready yet".
    func refreshGenre(_ id: Int) async {
        guard let model, let client = model.aurralClient, !model.isOffline, can.trending else { return }
        let scopeAtStart = scope
        do {
            let chart = try await client.trendingGenre(id)
            guard scope == scopeAtStart else { return }
            if let chart {
                genreCharts[id] = chart.items.map(ChartSong.init)
                notReadyGenres.remove(id)
                save()
            } else {
                notReadyGenres.insert(id)
            }
        } catch {
            model.noteAurralError(error)
        }
    }

    // MARK: - Not for me and Add flow (the owner's taps)

    /// Not for me: hidden here at once (and saved), then Aurral is told so it leaves the artist out (D92). A failed
    /// send keeps it hidden here.
    func notForMe(_ artist: AurralRecommendedArtist) async {
        hidden.insert(RecommendedRails.key(artist))
        save()
        model?.homeFeedSlot?.sectionsChanged(Set(HomeSection.recommendedSections))
        guard let model, let client = model.aurralClient, !model.isOffline, model.aurralCapabilities.discoverFeedback else { return }
        do { try await client.notForMe(artist) } catch { model.noteAurralError(error) }
    }

    func noteAdded(_ deezerPlaylistId: String, as playlistId: String) {
        added[deezerPlaylistId] = playlistId
        save()
    }

    // MARK: - HomeAurralShelves

    var availableSections: Set<HomeSection> {
        let can = can
        var sections: Set<HomeSection> = []
        if can.recommendations { sections.formUnion(HomeSection.recommendedSections) }
        if can.trending { sections.formUnion([.trending, .genreCharts]) }
        if can.editorial { sections.insert(.morePlaylists) }
        return sections
    }

    func items(for section: HomeSection, limit: Int) async throws -> [HomeOutsideItem] {
        guard let feed = Feed(section) else { return [] }
        await refresh(feed)
        guard has(feed) else { throw HomeSectionNotOffered() }   // never read: Home keeps its own copy and retries
        let items = homeItems(section, limit: limit)
        return items
    }

    /// A section's tiles from the feed as it stands.
    func homeItems(_ section: HomeSection, limit: Int) -> [HomeOutsideItem] {
        let limit = max(0, limit)
        switch section {
        case .recommended, .newThisWeek, .becauseYouLike, .closeToHome, .furtherOut:
            guard let rails = recommended?.rails(now: now(), hidden: hidden) else { return [] }
            func tiles(_ artists: [AurralRecommendedArtist], group: String? = nil) -> [HomeOutsideItem] {
                artists.map { a in
                    HomeOutsideItem(kind: .artist, key: a.mbid?.rawValue ?? RecommendedRails.key(a), title: a.name,
                                    subtitle: RecommendedRails.subtitle(a), artworkKey: a.image?.raw, group: group)
                }
            }
            switch section {
            case .recommended: return Array(tiles(rails.all).prefix(limit))
            case .newThisWeek: return Array(tiles(rails.newThisWeek).prefix(limit))
            case .closeToHome: return Array(tiles(rails.closeToHome).prefix(limit))
            case .furtherOut: return Array(tiles(rails.furtherOut).prefix(limit))
            default:
                let perRow = max(1, limit / HomeSectionStyle.becauseYouLikeRange.upperBound)
                return rails.becauseYouLike.flatMap { tiles(Array($0.artists.prefix(perRow)), group: $0.seed) }
            }
        case .trending:
            return (trending?.songs ?? []).prefix(limit).map { s in
                HomeOutsideItem(kind: .song, key: s.key ?? "\(s.position ?? 0)", title: s.title, subtitle: s.artist,
                                artworkKey: s.artwork?.raw)
            }
        case .genreCharts:
            return (trending?.genres ?? []).prefix(limit).map { g in
                HomeOutsideItem(kind: .genre, key: String(g.id), title: g.name,
                                subtitle: g.artists.isEmpty ? nil : g.artists.joined(separator: ", "), artworkKey: g.cover?.raw)
            }
        case .morePlaylists:
            guard let shelf = editorial?.shelfOfTheDay(now()) else { return [] }
            return shelf.playlists.prefix(limit).map(Self.playlistTile)
        default:
            return []
        }
    }

    /// Your flows' For you tiles (Home's first section, after the owner's flows).
    var forYouTiles: [HomeOutsideItem] { (editorial?.forYou ?? []).map(Self.playlistTile) }

    static func playlistTile(_ p: PlaylistSummary) -> HomeOutsideItem {
        HomeOutsideItem(kind: .playlist, key: p.id, title: p.name, subtitle: p.curator ?? DiscoverPagesCopy.songs(p.trackCount),
                        artworkKey: p.artwork?.raw)
    }

    func route(for item: HomeOutsideItem, in section: HomeSection) -> Route? {
        switch item.kind {
        case .artist:
            let mbid = MBID(item.key)
            return .outsideArtist(.init(name: item.title, mbid: mbid))
        case .song: return .trending
        case .genre: return Int(item.key).map { .genreChart(id: $0, name: item.title) }
        case .playlist: return .discoverPlaylist(id: item.key)
        case .album: return nil
        }
    }

    func artwork(for item: HomeOutsideItem, side: CGFloat) async -> UIImage? {
        await model?.aurralArtwork(item.artworkKey.flatMap(AurralImage.init), side: side)
    }
}

extension AurralFeeds.Feed {
    init?(_ section: HomeSection) {
        switch section {
        case .recommended, .newThisWeek, .becauseYouLike, .closeToHome, .furtherOut: self = .recommended
        case .trending, .genreCharts: self = .trending
        case .morePlaylists: self = .editorial
        default: return nil
        }
    }
}

extension AurralFeeds.Known {
    func has(_ feed: AurralFeeds.Feed) -> Bool {
        switch feed {
        case .trending: trending
        case .recommended: recommendations
        case .editorial: editorial
        }
    }
}

extension HomeSection {
    /// Round 14 A4: the sections Recommended fills.
    static let recommendedSections: [HomeSection] = [.recommended, .newThisWeek, .becauseYouLike, .closeToHome, .furtherOut]
}

extension AppModel {
    /// The feeds' disk copy follows the signed-in Navidrome account and Aurral user.
    var aurralFeedsScope: String? {
        guard let navidrome = navidromeScope, let connection = discover.connection else { return nil }
        return AurralFeeds.scope(navidrome: navidrome, aurralBase: connection.base, aurralUser: connection.username)
    }

    /// Hooks the feeds up as Home's provider, and keeps their disk copy and saved capabilities following the account.
    func wireAurralFeeds() {
        let feeds = AurralFeeds()
        feeds.model = self
        aurralFeeds = feeds
        homeAurralShelves = feeds
        feeds.follow(scope: aurralFeedsScope)
        Task { [weak self] in
            let scopes = Observations { @MainActor [weak self] in self?.aurralFeedsScope }
            for await scope in scopes {
                guard let self else { return }
                self.aurralFeeds.follow(scope: scope)
            }
        }
        Task { [weak self] in
            let capabilities = Observations { @MainActor [weak self] in
                self?.discover.bootstrap == nil ? nil : self?.aurralCapabilities
            }
            for await can in capabilities {
                guard let self else { return }
                if let can { self.aurralFeeds.note(can) }
            }
        }
    }

    // MARK: - Pictures

    /// A Discover, Trending or Recommended picture: only an https picture on a public image host (Deezer's, Apple's
    /// or another named by Aurral), fetched with no login and no cookies, kept in memory only. An Aurral path (it would
    /// need the session) shows the placeholder.
    func aurralArtwork(_ image: AurralImage?, side: CGFloat) async -> UIImage? {
        guard let image, !isOffline, !image.raw.hasPrefix("/"), let url = URL(string: image.raw),
              url.scheme?.lowercased() == "https", url.user == nil, let host = url.host()?.lowercased(),
              host.contains("."), !host.hasSuffix(".local"), !host.split(separator: ".").allSatisfy({ $0.allSatisfy(\.isNumber) })
        else { return nil }
        let scale = 3.0
        let key = "\(image.raw)#\(Int(side))" as NSString
        if let cached = AurralArtworkCache.shared.object(forKey: key) { return cached }
        var transport: HTTPTransport = OutsideArtTransport()
        #if DEBUG
        if let testing = Self.outsideArtTransportForTesting { transport = testing }
        #endif
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await transport.send(request), response.statusCode == 200,
              data.count <= OutsideArtPolicy.maxBytes, response.url?.scheme?.lowercased() == "https",
              let cg = OutsideArtLoader.decode(data, maxPixel: Int(side * scale)) else { return nil }
        let picture = UIImage(cgImage: cg)
        AurralArtworkCache.shared.setObject(picture, forKey: key)
        return picture
    }
}

/// Discover's pictures for this session, in memory only.
enum AurralArtworkCache {
    nonisolated(unsafe) static let shared: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 300
        return cache
    }()
}
