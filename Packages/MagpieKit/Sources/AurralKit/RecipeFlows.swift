import Foundation
import MagpieCore

// Round 16 (owner, 2026-11-05; docs/superpowers/specs/2026-11-05-magpie-recipe-flows-design.md): the user's own flows,
// made, edited and deleted from a recipe, as Aurral 2.13's web app does (`routes/playlists/handlers/flows.ts`):
// - made with `POST /api/playlists/flows {name, mix, size, deepDive, recentListening, autoDownload, yearFrom, yearTo,
//   tags, excludeTags, relatedArtists, scheduleDays, scheduleTime}`. 2.13 answers `{success, flow}` at once (a taken
//   name is a 400 there and then) and saves the flow **off**: it never runs until it is turned on, so Magpie turns it
//   on straight away with `PUT …/:id/enabled {enabled: true}` (the owner's "downloads as soon as it is created"),
//   which queues its first run. Magpie never sends `enabled: false` (that empties the flow);
// - edited with `PUT …/:id` and only the fields that changed (2.13 keeps the others; a year sent as null clears it).
//   The app then runs the flow (Refresh Flow's `POST /start/:id`) so its songs follow the new recipe;
// - deleted with `DELETE …/:id`. 2.13 queues it: the worker moves the files another Aurral playlist or flow uses and
//   deletes the rest of the flow's files (without the playback guard), then the flow.
// Aurral keeps the update time's hour only (`normalizeScheduleTime`) and the release filter as years.

/// Where a flow's songs come from (Aurral's `mix` keys; "Library" is `mix`, Aurral's Library Blend).
public enum FlowSource: String, CaseIterable, Sendable, Hashable {
    case discover, mix, trending, focus, newReleases
}

/// A flow's recipe, as Aurral 2.13 stores it (`flowPlaylistConfig.normalizeFlow`).
public struct FlowRecipe: Sendable, Hashable {
    public var name: String
    /// Round 27 D2 (owner, 2026-11-14): how many songs each source brings to an update, as Aurral's editor asks for
    /// them (a source at 0 is off; up to `maxSongsPerSource` to be sent). Supersedes round 16's shares (D316,
    /// supersedes D150). Fix round 1 (I4): never shrunk here (a flow made bigger on Aurral reads back whole and is
    /// refused, not cut, if a source is over 100); only held to 0…`maxStored`.
    public var counts: [FlowSource: Int] {
        didSet {
            for (source, n) in counts where !(0...Self.maxStored).contains(n) { counts[source] = min(max(n, 0), Self.maxStored) }
        }
    }
    /// Deeper cuts: less obvious songs.
    public var deepDive: Bool
    public var recentListening: Bool
    public var autoDownload: Bool
    public var yearFrom: Int?
    public var yearTo: Int?
    public var tags: [String]
    public var excludeTags: [String]
    public var relatedArtists: [String]
    /// 0 (Sunday) to 6.
    public var scheduleDays: [Int]
    /// 0–23 (Aurral keeps minutes at 00).
    public var scheduleHour: Int

    /// Fix round 1 (I4, as Aurral's editor: `MAX_SOURCE_TRACKS`): the most songs one source may bring.
    public static let maxSongsPerSource = 100
    /// The most songs a flow may hold: every source at its most (supersedes D148's 100).
    public static let maxSongs = maxSongsPerSource * FlowSource.allCases.count
    /// The largest size or count read from a server (a bound, not a rule).
    static let maxStored = 10_000
    public static let defaultSize = 30
    /// Round 27 D2: what checking a source in the editor gives it (D316).
    public static let countWhenPicked = 10
    public static let maxListItems = 25
    public static let maxItemLength = 100
    public static let maxNameLength = 200

    /// The default recipe: Discover, Library and Trending, ten songs each (Aurral's 30).
    public init(name: String, counts: [FlowSource: Int] = [.discover: 10, .mix: 10, .trending: 10], deepDive: Bool = false,
                recentListening: Bool = false, autoDownload: Bool = true, yearFrom: Int? = nil, yearTo: Int? = nil,
                tags: [String] = [], excludeTags: [String] = [], relatedArtists: [String] = [],
                scheduleDays: [Int] = [5], scheduleHour: Int = 0) {
        self.name = name; self.counts = counts.mapValues { min(max($0, 0), Self.maxStored) }; self.deepDive = deepDive
        self.recentListening = recentListening; self.autoDownload = autoDownload; self.yearFrom = yearFrom
        self.yearTo = yearTo; self.tags = tags; self.excludeTags = excludeTags; self.relatedArtists = relatedArtists
        self.scheduleDays = scheduleDays; self.scheduleHour = scheduleHour
    }

    /// Round 27 D2: how many songs an update brings: the counts' sum (Aurral's `flowDraftTotal`), at least 1 to be
    /// sent (supersedes D148: the size is no longer a field of its own; fix round 1: up to 500, 100 a source) (D316).
    public var size: Int { FlowSource.allCases.reduce(0) { $0 + (counts[$1] ?? 0) } }

    /// The sources picked (count above 0), in Aurral's order.
    public var sources: [FlowSource] { FlowSource.allCases.filter { (counts[$0] ?? 0) > 0 } }

    /// Round 27 D2: the editor's checkmark: on gives the source ten songs (unless it has some), off gives it none (D316).
    public mutating func setSource(_ source: FlowSource, on: Bool) {
        if on { if (counts[source] ?? 0) == 0 { counts[source] = Self.countWhenPicked } } else { counts[source] = 0 }
    }

    /// Round 27 D2: Aurral's `splitFlowTotal` (`lib/flows.ts`): `total` songs split over the sources by their weights,
    /// each the floor of its exact share, the rest one each to the largest remainders (ties in source order, as
    /// JavaScript's stable sort leaves them). Nil when no weight is above 0. How a stored mix (Aurral normalises it to
    /// percentages) becomes counts again (D316).
    public static func splitFlowTotal(_ weights: [FlowSource: Double], total: Int) -> [FlowSource: Int]? {
        let shares = FlowSource.allCases.map { source -> Double in
            let w = weights[source] ?? 0
            return w.isFinite && w > 0 ? w : 0
        }
        let sum = shares.reduce(0, +)
        guard sum > 0, sum.isFinite else { return nil }
        let total = max(total, 0)
        let exact = shares.map { $0 / sum * Double(total) }
        var counts = exact.map { Int($0.rounded(.down)) }
        var left = total - counts.reduce(0, +)
        let order = exact.indices.sorted { a, b in
            let ra = exact[a] - exact[a].rounded(.down), rb = exact[b] - exact[b].rounded(.down)
            return ra != rb ? ra > rb : a < b
        }
        for index in order where left > 0 {
            counts[index] += 1
            left -= 1
        }
        return Dictionary(uniqueKeysWithValues: zip(FlowSource.allCases, counts))
    }

    /// Fields only Advanced shows are in use (round 27 D2: counts show in both, D316).
    public var usesAdvanced: Bool {
        !excludeTags.isEmpty || !relatedArtists.isEmpty || !autoDownload
            || (recentListening && !(sources.contains(.focus) && tags.isEmpty))
    }

    /// What's wrong with it (in the user's words), or nil when Aurral would take it.
    public var problem: String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return "Give the flow a name." }
        if name.count > Self.maxNameLength { return "That name is too long." }
        // Round 27 D2: at least one song, at most 100 a source (fix round 1, I4: as Aurral), refused unsent (D316).
        if size < 1 { return "Choose at least one song." }
        if counts.values.contains(where: { $0 > Self.maxSongsPerSource }) {
            return "A source holds up to \(Self.maxSongsPerSource) songs."
        }
        if scheduleDays.isEmpty || !scheduleDays.allSatisfy((0...6).contains) { return "Pick at least one day to update on." }
        if !(0...23).contains(scheduleHour) { return "Pick an hour to update at." }
        for year in [yearFrom, yearTo].compactMap({ $0 }) where !(1000...9999).contains(year) {
            return "Years have four digits."
        }
        for list in [tags, excludeTags, relatedArtists] {
            if list.count > Self.maxListItems { return "That\u{2019}s too many (at most \(Self.maxListItems))." }
            if list.contains(where: { $0.count > Self.maxItemLength || $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                return "One of the tags or artists is too long."
            }
        }
        if sources.contains(.focus), tags.isEmpty, relatedArtists.isEmpty, !recentListening {
            return "Focus needs a tag, a similar artist or your recent listening."
        }
        return nil
    }

    /// Every field, as Aurral's create takes them.
    var fields: [String: Any] {
        [
            "name": name.trimmingCharacters(in: .whitespacesAndNewlines),
            "size": size,
            // Round 27 D2: the counts themselves, all five keys (Aurral normalises them to percentages) (D316).
            "mix": Dictionary(uniqueKeysWithValues: FlowSource.allCases.map { ($0.rawValue, max(0, counts[$0] ?? 0)) }),
            "deepDive": deepDive,
            "recentListening": recentListening,
            "autoDownload": autoDownload,
            "yearFrom": yearFrom.map { $0 as Any } ?? NSNull(),
            "yearTo": yearTo.map { $0 as Any } ?? NSNull(),
            "tags": Self.clean(tags),
            "excludeTags": Self.clean(excludeTags),
            "relatedArtists": Self.clean(relatedArtists),
            "scheduleDays": scheduleDays.sorted(),
            "scheduleTime": String(format: "%02d:00", scheduleHour),
        ]
    }

    /// The fields that differ between `old` and this recipe (what an edit sends; empty: nothing changed).
    public func changes(from old: FlowRecipe) -> [String: Any] {
        let new = fields, before = old.fields
        var out: [String: Any] = [:]
        for (key, value) in new where !Self.same(value, before[key]) { out[key] = value }
        return out
    }

    static func same(_ a: Any, _ b: Any?) -> Bool {
        guard let b else { return false }
        return (a as? NSObject)?.isEqual(b as? NSObject) ?? false
    }

    static func clean(_ list: [String]) -> [String] {
        var seen = Set<String>()
        return list.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    /// A flow in Aurral's status (`flows[]`), read leniently; nil without a name.
    static func decode(_ f: [String: Any]) -> FlowRecipe? {
        guard let name = f.string("name") else { return nil }
        // Round 27 D2: the stored mix and size back to counts, as Aurral's editor does (`splitFlowTotal`) (D316).
        var weights: [FlowSource: Double] = [:]
        let mix = f.dict("mix") ?? [:]
        for source in FlowSource.allCases {
            if let n = mix[source.rawValue] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite,
               n.doubleValue > 0 {
                weights[source] = n.doubleValue
            }
        }
        let size = min(max(f.int("size") ?? defaultSize, 1), maxStored)   // fix round 1 (I4): the real size
        let counts = splitFlowTotal(weights, total: size) ?? [:]
        let days = (f["scheduleDays"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.intValue }.filter((0...6).contains)
        let hour = f.string("scheduleTime").flatMap { Int($0.split(separator: ":").first ?? "") }.flatMap {
            (0...23).contains($0) ? $0 : nil
        } ?? 0
        return FlowRecipe(name: name, counts: counts,
                          deepDive: f.bool("deepDive") ?? false, recentListening: f.bool("recentListening") ?? false,
                          autoDownload: f.bool("autoDownload") ?? true, yearFrom: f.int("yearFrom"), yearTo: f.int("yearTo"),
                          tags: f.strings("tags", cap: maxListItems), excludeTags: f.strings("excludeTags", cap: maxListItems),
                          relatedArtists: f.strings("relatedArtists", cap: maxListItems),
                          scheduleDays: Array(Set(days)).sorted(), scheduleHour: hour)
    }
}

extension AurralClient {
    static func recipeFlowBody(_ object: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    /// New flow: `POST /api/playlists/flows` with the whole recipe (accessFlow). Answers the new flow's id; a 400 is a
    /// refusal (a name the user already has, a recipe Aurral won't take).
    public func createRecipeFlow(_ recipe: FlowRecipe) async throws -> String {
        guard recipe.problem == nil, let body = Self.recipeFlowBody(recipe.fields) else {
            throw AurralError.forbidden("recipe flow: \(recipe.problem ?? "body")")
        }
        let data = try await ok(method: AurralRoute.recipeFlowCreateMethod, path: "api/playlists/flows", body: body)
        guard let o = object(data) as? [String: Any], let id = o.dict("flow")?.idText("id"),
              AurralRoute.isPlainId(Substring(id)) else { throw AurralError.decoding }
        return id
    }

    /// Turns a flow just made on: `PUT /api/playlists/flows/:id/enabled {enabled: true}`. Aurral schedules it and
    /// queues its first run now (its songs download). Never sent with false.
    public func turnOnRecipeFlow(_ flowId: String) async throws {
        guard AurralRoute.isPlainId(Substring(flowId)),
              let body = Self.recipeFlowBody(["enabled": true]) else { throw AurralError.forbidden("turn on \(flowId.count) chars") }
        _ = try await ok(method: AurralRoute.recipeFlowTurnOnMethod, path: "api/playlists/flows/" + flowId + "/enabled", body: body)
    }

    /// Edit flow: `PUT /api/playlists/flows/:id` with only the fields that changed from `old`. Nothing is sent when
    /// nothing changed (answers false). `notFound`: the flow is gone.
    @discardableResult
    public func updateRecipeFlow(_ flowId: String, from old: FlowRecipe, to new: FlowRecipe) async throws -> Bool {
        guard AurralRoute.isPlainId(Substring(flowId)), new.problem == nil else {
            throw AurralError.forbidden("recipe flow \(flowId.count) chars: \(new.problem ?? "")")
        }
        let changes = new.changes(from: old)
        guard !changes.isEmpty else { return false }
        guard let body = Self.recipeFlowBody(changes) else { throw AurralError.forbidden("recipe flow body") }
        _ = try await ok(method: AurralRoute.recipeFlowUpdateMethod, path: "api/playlists/flows/" + flowId, body: body)
        return true
    }

    /// Delete flow: `DELETE /api/playlists/flows/:id` (no body). Aurral queues it; a flow already gone (404) is deleted.
    public func deleteRecipeFlow(_ flowId: String) async throws {
        guard AurralRoute.isPlainId(Substring(flowId)) else { throw AurralError.forbidden("recipe flow \(flowId.count) chars") }
        _ = try await deleteFlow(flowId)   // round 24 B (D208): the one send, in AurralClient+Manage.swift
    }
}
