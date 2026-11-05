import Foundation
import MagpieCore

// Round 15 C2 (owner items 5 and 5b, D130–D134): a flow of a chart's top N songs.
//
// Aurral 2.13's Add flow (`POST /api/discover/editorial/:id/library`) takes no song count: it imports the whole chart as
// a synced playlist that re-syncs every day and keeps songs that fell off (`keepRemovedTracks: true`), so it can be
// neither shortened nor limited. A chart flow is instead one of the user's own Aurral playlists ("shared playlists",
// `routes/playlists/handlers/staticPlaylists.ts`) holding exactly the chart's top N, which its owner may give a new
// song list (`PUT`, Aurral keeps the songs still in, drops the rest and queues the new ones) or remove (`DELETE`).
// Aurral matches, downloads (its own download sources) and publishes it to Navidrome, as for Add flow.

/// One song sent to Aurral for a chart flow: only the fields Aurral 2.13's playlist track takes and the chart gives.
public struct ChartFlowTrack: Sendable, Equatable, Hashable, Codable {
    public var artistName: String
    public var trackName: String
    public var albumName: String?
    public var durationMs: Int?

    public init(artistName: String, trackName: String, albumName: String?, durationMs: Int?) {
        self.artistName = artistName; self.trackName = trackName; self.albumName = albumName; self.durationMs = durationMs
    }

    /// The JSON object Aurral takes (`artistName`, `trackName`, and `albumName` / `durationMs` when known).
    var json: [String: Any] {
        var o: [String: Any] = ["artistName": artistName.trimmingCharacters(in: .whitespacesAndNewlines),
                                "trackName": trackName.trimmingCharacters(in: .whitespacesAndNewlines)]
        if let album = albumName?.trimmingCharacters(in: .whitespacesAndNewlines), !album.isEmpty { o["albumName"] = String(album.prefix(300)) }
        if let durationMs, durationMs > 0 { o["durationMs"] = durationMs }
        return o
    }
}

/// Which songs a chart flow holds, and the counts offered.
public enum ChartFlowPlan {
    /// The most a chart flow holds (Aurral's charts list at most 100 songs).
    public static let maxSongs = 100
    /// The counts offered as quick picks (each up to the chart's length, which is offered too).
    public static let commonCounts = [10, 20, 25, 50, 100]

    /// The chart's first `count` songs (at least 1, at most the chart's length and `maxSongs`), skipping a song with no
    /// artist or title and a repeat (same artist and title, case, accents and spacing folded), in chart order.
    public static func tracks(from songs: [ChartFlowTrack], count: Int) -> [ChartFlowTrack] {
        let wanted = min(max(1, count), maxSongs)
        var seen = Set<String>()
        var picked: [ChartFlowTrack] = []
        for song in songs where picked.count < wanted {
            let artist = fold(song.artistName), title = fold(song.trackName)
            guard !artist.isEmpty, !title.isEmpty, seen.insert(artist + "\u{1}" + title).inserted else { continue }
            var clean = song
            clean.artistName = song.artistName.trimmingCharacters(in: .whitespacesAndNewlines)
            clean.trackName = song.trackName.trimmingCharacters(in: .whitespacesAndNewlines)
            picked.append(clean)
        }
        return picked
    }

    /// The quick picks for a chart of `chartLength` songs: the common counts below it, then the whole chart.
    public static func presets(chartLength: Int) -> [Int] {
        let length = min(chartLength, maxSongs)
        guard length > 0 else { return [] }
        return commonCounts.filter { $0 < length } + [length]
    }

    /// What "Songs: N" starts at for a new flow: 25, or the whole chart when it is shorter.
    public static func defaultCount(chartLength: Int) -> Int { max(1, min(25, chartLength, maxSongs)) }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// One chart's flow (D133): the user's Aurral playlist for it, its name and how many top songs it holds.
public struct ChartFlow: Sendable, Equatable, Codable {
    /// `TrendingChart.key` ("worldwide", "country:AU", "genre:132").
    public var chartKey: String
    /// The Aurral playlist's id.
    public var playlistId: String
    public var name: String
    /// How many of the chart's top songs it holds (the owner's N).
    public var count: Int
    public var createdAt: Date
    /// When its songs were last sent (Create, Refresh now, Songs: N).
    public var refreshedAt: Date

    public init(chartKey: String, playlistId: String, name: String, count: Int, createdAt: Date, refreshedAt: Date) {
        self.chartKey = chartKey; self.playlistId = playlistId; self.name = name; self.count = count
        self.createdAt = createdAt; self.refreshedAt = refreshedAt
    }
}

/// Every chart's flow for one Navidrome account and Aurral user (saved with Discover's feeds, removed on sign-out).
public struct ChartFlowBook: Sendable, Equatable, Codable {
    public private(set) var flows: [ChartFlow] = []

    public init() {}

    public func flow(for chartKey: String) -> ChartFlow? { flows.first { $0.chartKey == chartKey } }

    /// Sets the chart's flow (replacing any it had).
    public mutating func set(_ flow: ChartFlow) {
        if let index = flows.firstIndex(where: { $0.chartKey == flow.chartKey }) { flows[index] = flow } else { flows.append(flow) }
    }

    /// The chart's flow now holds `count` songs, sent at `date`.
    public mutating func resize(_ chartKey: String, to count: Int, at date: Date) {
        guard let index = flows.firstIndex(where: { $0.chartKey == chartKey }) else { return }
        flows[index].count = count
        flows[index].refreshedAt = date
    }

    public mutating func remove(_ chartKey: String) { flows.removeAll { $0.chartKey == chartKey } }

    /// The Aurral playlists Magpie made for charts (Discover's, D94's "an id this phone added").
    public var playlistIds: [String] { flows.map(\.playlistId) }

    public func chartKey(forPlaylist id: String) -> String? { flows.first { $0.playlistId == id }?.chartKey }
}

/// A chart flow's create answer (`{success, playlistId, queued, operationId}`): Aurral queues the creation.
public struct AurralChartFlowCreated: Sendable, Equatable {
    public var playlistId: String
    public var operationId: String?

    public init(playlistId: String, operationId: String? = nil) { self.playlistId = playlistId; self.operationId = operationId }

    static func decode(_ data: Data) throws -> AurralChartFlowCreated {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let id = o["playlistId"] as? String, AurralRoute.isPlainId(Substring(id)) else { throw AurralError.decoding }
        return AurralChartFlowCreated(playlistId: id, operationId: (o["operationId"] as? String).map { String($0.prefix(100)) })
    }
}

extension AurralClient {
    /// The source name Magpie gives a chart flow in Aurral.
    static let chartFlowSourceName = "Charts"

    /// The body of a chart flow's create (`name`, `sourceName`, `tracks`) or song update (`tracks` only).
    static func chartFlowBody(name: String?, tracks: [ChartFlowTrack]) -> Data? {
        var o: [String: Any] = ["tracks": tracks.map(\.json)]
        if let name {
            o["name"] = name
            o["sourceName"] = chartFlowSourceName
        }
        return try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    static func validChartFlowSongs(_ tracks: [ChartFlowTrack]) -> Bool {
        (1...ChartFlowPlan.maxSongs).contains(tracks.count)
            && tracks.allSatisfy { !ChartFlowPlan.fold($0.artistName).isEmpty && !ChartFlowPlan.fold($0.trackName).isEmpty }
    }

    /// Create flow: `POST /api/playlists/shared-playlists {name, sourceName, tracks}` (accessFlow). Aurral queues the
    /// playlist's creation, then downloads and publishes it. `nameTaken`: the user already has a playlist so named.
    public func createChartFlow(name: String, tracks: [ChartFlowTrack]) async throws -> AurralChartFlowCreated {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 200, Self.validChartFlowSongs(tracks),
              let body = Self.chartFlowBody(name: name, tracks: tracks) else {
            throw AurralError.forbidden("chart flow \(name.count) chars, \(tracks.count) songs")
        }
        do {
            return try AurralChartFlowCreated.decode(
                try await ok(method: AurralRoute.chartFlowCreateMethod, path: "api/playlists/shared-playlists", body: body))
        } catch AurralError.http(status: 400) { throw AurralError.nameTaken }
    }

    /// Refresh now and Songs: N: `PUT /api/playlists/shared-playlists/:id {tracks}`. Aurral keeps the songs still in,
    /// takes out the rest and queues the new ones. `notFound`: the playlist is gone.
    public func updateChartFlow(playlistId: String, tracks: [ChartFlowTrack]) async throws -> AurralQueued {
        guard AurralRoute.isPlainId(Substring(playlistId)), Self.validChartFlowSongs(tracks),
              let body = Self.chartFlowBody(name: nil, tracks: tracks) else {
            throw AurralError.forbidden("chart flow \(playlistId.count) chars, \(tracks.count) songs")
        }
        return try AurralQueued.decode(try await ok(method: AurralRoute.chartFlowUpdateMethod,
                                                    path: "api/playlists/shared-playlists/" + playlistId, body: body))
    }

    /// Remove flow: `DELETE /api/playlists/shared-playlists/:id` (no body). A playlist already gone (404) is removed.
    public func deleteChartFlow(playlistId: String) async throws {
        guard AurralRoute.isPlainId(Substring(playlistId)) else { throw AurralError.forbidden("chart flow \(playlistId.count) chars") }
        do {
            _ = try await ok(method: AurralRoute.chartFlowDeleteMethod, path: "api/playlists/shared-playlists/" + playlistId)
        } catch AurralError.notFound { return }
    }
}
