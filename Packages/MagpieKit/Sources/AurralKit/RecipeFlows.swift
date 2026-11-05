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
    /// How many songs each update brings (Aurral's default 30; Magpie offers 1–100).
    public var size: Int
    /// Each source's share (Aurral normalises them to percentages); a source at 0 is off.
    public var shares: [FlowSource: Int]
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

    public static let maxSongs = 100
    public static let defaultSize = 30
    public static let maxListItems = 25
    public static let maxItemLength = 100
    public static let maxNameLength = 200

    public init(name: String, size: Int = FlowRecipe.defaultSize,
                shares: [FlowSource: Int] = [.discover: 34, .mix: 33, .trending: 33], deepDive: Bool = false,
                recentListening: Bool = false, autoDownload: Bool = true, yearFrom: Int? = nil, yearTo: Int? = nil,
                tags: [String] = [], excludeTags: [String] = [], relatedArtists: [String] = [],
                scheduleDays: [Int] = [5], scheduleHour: Int = 0) {
        self.name = name; self.size = size; self.shares = shares; self.deepDive = deepDive
        self.recentListening = recentListening; self.autoDownload = autoDownload; self.yearFrom = yearFrom
        self.yearTo = yearTo; self.tags = tags; self.excludeTags = excludeTags; self.relatedArtists = relatedArtists
        self.scheduleDays = scheduleDays; self.scheduleHour = scheduleHour
    }

    /// The sources picked (share above 0), in Aurral's order.
    public var sources: [FlowSource] { FlowSource.allCases.filter { (shares[$0] ?? 0) > 0 } }

    /// Every picked source the same share (Simple's chips).
    public mutating func setSources(_ picked: Set<FlowSource>) {
        let ordered = FlowSource.allCases.filter(picked.contains)
        shares = [:]
        guard !ordered.isEmpty else { return }
        let each = 100 / ordered.count
        for (index, source) in ordered.enumerated() { shares[source] = each + (index < 100 % ordered.count ? 1 : 0) }
    }

    /// Shares that aren't equal: Simple can't show them.
    public var hasUnevenShares: Bool {
        let values = sources.map { shares[$0] ?? 0 }
        return (values.max() ?? 0) - (values.min() ?? 0) > 1
    }

    /// Fields only Advanced shows are in use.
    public var usesAdvanced: Bool {
        hasUnevenShares || !excludeTags.isEmpty || !relatedArtists.isEmpty || !autoDownload
            || (recentListening && !(sources.contains(.focus) && tags.isEmpty))
    }

    /// What's wrong with it (in the user's words), or nil when Aurral would take it.
    public var problem: String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return "Give the flow a name." }
        if name.count > Self.maxNameLength { return "That name is too long." }
        if !(1...Self.maxSongs).contains(size) { return "A flow holds 1 to \(Self.maxSongs) songs." }
        if sources.isEmpty { return "Pick at least one source." }
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
            "mix": Dictionary(uniqueKeysWithValues: FlowSource.allCases.map { ($0.rawValue, max(0, shares[$0] ?? 0)) }),
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
        var shares: [FlowSource: Int] = [:]
        let mix = f.dict("mix") ?? [:]
        for source in FlowSource.allCases {
            if let n = mix[source.rawValue] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite,
               n.doubleValue > 0 {
                shares[source] = max(1, Int(n.doubleValue.rounded()))
            }
        }
        let days = (f["scheduleDays"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.intValue }.filter((0...6).contains)
        let hour = f.string("scheduleTime").flatMap { Int($0.split(separator: ":").first ?? "") }.flatMap {
            (0...23).contains($0) ? $0 : nil
        } ?? 0
        return FlowRecipe(name: name, size: min(max(f.int("size") ?? defaultSize, 1), maxSongs), shares: shares,
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
        do {
            _ = try await ok(method: AurralRoute.recipeFlowDeleteMethod, path: "api/playlists/flows/" + flowId)
        } catch AurralError.notFound { return }
    }
}
