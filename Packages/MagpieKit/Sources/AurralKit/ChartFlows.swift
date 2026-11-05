import Foundation
import MagpieCore

// Round 15 C2 (owner items 5 and 5b, D130–D134): a flow of a chart's top N songs.
//
// Aurral 2.13's Add flow (`POST /api/discover/editorial/:id/library`) takes no song count: it imports the whole chart as
// a synced playlist that re-syncs every day and keeps songs that fell off (`keepRemovedTracks: true`), so it can be
// neither shortened nor limited. A chart flow is instead one of the user's own Aurral playlists ("shared playlists",
// `routes/playlists/handlers/staticPlaylists.ts`) holding exactly the chart's top N:
// - made with `POST /api/playlists/shared-playlists {name, sourceName, tracks}`. 2.13 **queues** the creation and
//   answers 200 whatever the name; a name the user already has (a playlist or a flow, trimmed and case folded) fails
//   later in the worker and the playlist never appears. So Magpie picks a free name first (`ChartFlowPlan.freeName`)
//   and gives up on a creation the server never lists (fix round I1);
// - songs that leave go with `POST …/:id/track-removals {jobIds}` (2.13's bulk remove: `deleteFiles: true`, so their
//   files are deleted, but only inside Aurral's own download folder, never a file reused from the library
//   (`externalPath`), one another Aurral playlist or flow uses (moved to it instead) or one a visible Navidrome playlist
//   still points at); songs that come in go with `POST …/:id/tracks {tracks}` (fix round I2: the `PUT` that replaced
//   the list left the removed songs' files behind for good);
// - removed with `DELETE …/:id` (the same file rules).
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

/// Which songs a chart flow holds, the counts offered, its name and what changes.
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
            let key = songKey(song.artistName, song.trackName)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
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

    /// Fix round I1: the first of `base`, "`base` 2", "`base` 3"… that none of `taken` is (trimmed and lower-cased, as
    /// Aurral's `normalizeNameKey` compares the user's playlists and flows).
    public static func freeName(_ base: String, taken: [String]) -> String {
        let used = Set(taken.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        let base = base.trimmingCharacters(in: .whitespacesAndNewlines)
        if !used.contains(base.lowercased()) { return base }
        var n = 2
        while used.contains("\(base) \(n)".lowercased()) { n += 1 }
        return "\(base) \(n)"
    }

    /// Fix round I2: what changes to make the flow (its songs as Aurral's jobs) hold `wanted`: the jobs to take out
    /// (songs no longer wanted, and any second job for one song) and the songs to add, in chart order.
    public static func changes(jobs: [AurralJob], wanted: [ChartFlowTrack]) -> (remove: [String], add: [ChartFlowTrack]) {
        let wantedKeys = Set(wanted.map { songKey($0.artistName, $0.trackName) })
        var kept = Set<String>()
        var remove: [String] = []
        for job in jobs {
            let key = songKey(job.artistName, job.trackName)
            if wantedKeys.contains(key), kept.insert(key).inserted { continue }
            remove.append(job.id)
        }
        let add = wanted.filter { !kept.contains(songKey($0.artistName, $0.trackName)) }
        return (remove, add)
    }

    static func songKey(_ artist: String, _ title: String) -> String {
        let a = fold(artist), t = fold(title)
        return a.isEmpty || t.isEmpty ? "" : a + "\u{1}" + t
    }

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
    /// Fix round M2: the server has listed it (its creation went through), so it can be edited or removed.
    public var confirmed: Bool

    public init(chartKey: String, playlistId: String, name: String, count: Int, createdAt: Date, refreshedAt: Date,
                confirmed: Bool = false) {
        self.chartKey = chartKey; self.playlistId = playlistId; self.name = name; self.count = count
        self.createdAt = createdAt; self.refreshedAt = refreshedAt; self.confirmed = confirmed
    }

    enum CodingKeys: String, CodingKey { case chartKey, playlistId, name, count, createdAt, refreshedAt, confirmed }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        chartKey = try c.decode(String.self, forKey: .chartKey)
        playlistId = try c.decode(String.self, forKey: .playlistId)
        name = try c.decode(String.self, forKey: .name)
        count = try c.decode(Int.self, forKey: .count)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        refreshedAt = try c.decode(Date.self, forKey: .refreshedAt)
        confirmed = (try? c.decodeIfPresent(Bool.self, forKey: .confirmed)) ?? false
    }
}

/// Every chart's flow for one Navidrome account and Aurral user (saved with Discover's feeds, removed on sign-out).
public struct ChartFlowBook: Sendable, Equatable, Codable {
    public private(set) var flows: [ChartFlow] = []

    public init() {}

    /// Fix round M3: an entry this build can't read (a later build's) is dropped on its own, never the whole book.
    public init(from decoder: Decoder) throws {
        struct Lenient: Decodable {
            let flow: ChartFlow?
            init(from decoder: Decoder) throws { flow = try? ChartFlow(from: decoder) }
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        flows = ((try? c.decodeIfPresent([Lenient].self, forKey: .flows)) ?? nil)?.compactMap(\.flow) ?? []
    }

    enum CodingKeys: String, CodingKey { case flows }

    public func flow(for chartKey: String) -> ChartFlow? { flows.first { $0.chartKey == chartKey } }

    /// Sets the chart's flow (replacing any it had).
    public mutating func set(_ flow: ChartFlow) {
        if let index = flows.firstIndex(where: { $0.chartKey == flow.chartKey }) { flows[index] = flow } else { flows.append(flow) }
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
    /// The source name Magpie gives a chart flow in Aurral (how one is recognised again: fix round M3).
    public static let chartFlowSourceName = "Charts"

    /// The body of a chart flow's create (`name`, `sourceName`, `tracks`) or song append (`tracks` only).
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
            && tracks.allSatisfy { !ChartFlowPlan.songKey($0.artistName, $0.trackName).isEmpty }
    }

    /// Create flow: `POST /api/playlists/shared-playlists {name, sourceName, tracks}` (accessFlow). Aurral queues the
    /// creation: the answer's id is listed in the status only once the worker made it (a name the user already has
    /// fails there, so the caller picks a free one first).
    public func createChartFlow(name: String, tracks: [ChartFlowTrack]) async throws -> AurralChartFlowCreated {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 200, Self.validChartFlowSongs(tracks),
              let body = Self.chartFlowBody(name: name, tracks: tracks) else {
            throw AurralError.forbidden("chart flow \(name.count) chars, \(tracks.count) songs")
        }
        return try AurralChartFlowCreated.decode(
            try await ok(method: AurralRoute.chartFlowCreateMethod, path: "api/playlists/shared-playlists", body: body))
    }

    /// Songs that come in (Songs: N higher, Refresh now): `POST /api/playlists/shared-playlists/:id/tracks {tracks}`.
    /// Aurral adds the ones it doesn't have and queues them. `notFound`: the playlist is gone.
    public func appendChartFlowSongs(playlistId: String, tracks: [ChartFlowTrack]) async throws -> AurralQueued {
        guard AurralRoute.isPlainId(Substring(playlistId)), Self.validChartFlowSongs(tracks),
              let body = Self.chartFlowBody(name: nil, tracks: tracks) else {
            throw AurralError.forbidden("chart flow \(playlistId.count) chars, \(tracks.count) songs")
        }
        return try AurralQueued.decode(try await ok(method: AurralRoute.chartFlowAppendMethod,
                                                    path: "api/playlists/shared-playlists/" + playlistId + "/tracks", body: body))
    }

    /// Songs that leave (Songs: N lower, Refresh now): `POST /api/playlists/shared-playlists/:id/track-removals
    /// {jobIds}` (1–100 of the playlist's job ids). Aurral takes them out and deletes their files under its own rules
    /// (see the top of this file). Answers the job ids it accepted. `notFound`: the playlist is gone.
    public func removeChartFlowSongs(playlistId: String, jobIds: [String]) async throws -> [String] {
        guard AurralRoute.isPlainId(Substring(playlistId)), (1...ChartFlowPlan.maxSongs).contains(jobIds.count),
              jobIds.allSatisfy({ AurralRoute.isPlainId(Substring($0)) }),
              let body = try? JSONSerialization.data(withJSONObject: ["jobIds": jobIds], options: [.sortedKeys]) else {
            throw AurralError.forbidden("chart flow removal \(playlistId.count) chars, \(jobIds.count) songs")
        }
        let data = try await ok(method: AurralRoute.chartFlowRemoveSongsMethod,
                                path: "api/playlists/shared-playlists/" + playlistId + "/track-removals", body: body)
        let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return (o?["acceptedJobIds"] as? [String] ?? []).filter(jobIds.contains)
    }

    /// Remove flow: `DELETE /api/playlists/shared-playlists/:id` (no body). A playlist already gone (404) is removed.
    public func deleteChartFlow(playlistId: String) async throws {
        guard AurralRoute.isPlainId(Substring(playlistId)) else { throw AurralError.forbidden("chart flow \(playlistId.count) chars") }
        do {
            _ = try await ok(method: AurralRoute.chartFlowDeleteMethod, path: "api/playlists/shared-playlists/" + playlistId)
        } catch AurralError.notFound { return }
    }
}
