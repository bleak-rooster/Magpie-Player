import AurralKit
import Foundation
import MagpieCore

/// Round 16 (owner, 2026-11-05; docs/superpowers/specs/2026-11-05-magpie-recipe-flows-design.md): the user's own
/// flows, made, edited and deleted from a recipe in Discover.
///
/// - Every recipe flow under the user's name (the status is already scoped to them: `AurralStatus.scoped(to:)`),
///   wherever it was made, may be edited and deleted; only with accessFlow on an Aurral that has flows.
/// - New flow: the recipe is sent, then the flow is turned on at once so its first songs download (Aurral saves a new
///   flow off). There is no turn off.
/// - Edit flow: only the fields that changed are sent, then the flow is run so its songs follow the new recipe (a run
///   under way is waited for, up to `editRunWait`).
/// - Delete flow: Aurral queues it; the flow leaves Your flows at once and is never shown again while the delete waits.
extension AppModel {
    /// Your flows' controls may show: this Aurral has flows and its user has accessFlow (or is an admin).
    var aurralCanManageFlows: Bool {
        aurralCapabilities.playlistJobsById && discover.bootstrap?.user?.canAddFlow == true
    }

    /// The user's recipe flows, as the status last listed them (deleted ones left out).
    var recipeFlows: [AurralFlow] {
        (discover.status?.flows ?? []).filter { $0.recipe != nil && !discover.deletingFlowIds.contains($0.id) }
    }

    func recipeFlow(id: String) -> AurralFlow? { recipeFlows.first { $0.id == id } }

    /// Owner (2026-11-05): a flow whose songs are still being fetched or downloaded in the background shows greyed out
    /// in Your flows, with its progress. Nil once its songs are in (or it is off).
    func recipeFlowDownload(_ flow: AurralFlow) -> RecipeFlowDownload? {
        guard flow.enabled else { return nil }
        let stats = discover.status?.flowStats[flow.id]
        let waiting = (stats?.pending ?? 0) + (stats?.downloading ?? 0)
        if waiting > 0, let total = stats?.total, total > 0 {
            return .downloading(done: min(total, max(0, stats?.done ?? 0)), total: total)
        }
        // Just made or just edited: its run hasn't listed songs yet.
        if discover.refreshing[flow.id] != nil || (flow.lastRunAt == nil && (stats?.total ?? 0) == 0) { return .gettingSongs }
        return nil
    }

    /// A new recipe: Discover, Library and Trending, 30 songs, Fridays at midnight, under a free name.
    func newFlowRecipe() -> FlowRecipe {
        let taken = (discover.status?.flows ?? []).map(\.name) + (discover.status?.sharedPlaylists ?? []).map(\.name)
        return FlowRecipe(name: ChartFlowPlan.freeName(RecipeFlowCopy.defaultName, taken: taken))
    }

    private func recipeFlowClient() throws -> AurralClient {
        guard !isOffline else { throw Self.forcedOfflineError }
        guard aurralCanManageFlows, let client = aurralClient else { throw AurralError.notPermitted }
        return client
    }

    /// The names the user's flows and playlists have on the server now (read fresh; a failed read sends nothing).
    private func takenFlowNames(_ client: AurralClient, except flowId: String? = nil) async throws -> Set<String> {
        let status: AurralStatus
        do { status = try await client.status() } catch {
            noteAurralError(error)
            throw error
        }
        noteStatus(status)
        let names = status.flows.filter { $0.id != flowId }.map(\.name) + status.sharedPlaylists.map(\.name)
        return Set(names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
    }

    /// New flow: made on the server, then turned on so its songs download now. Answers the new flow's id.
    @discardableResult
    func createRecipeFlow(_ recipe: FlowRecipe) async throws -> String {
        let client = try recipeFlowClient()
        let recipe = Self.prepared(recipe)
        if let problem = recipe.problem { throw RecipeFlowError.invalid(problem) }
        let key = recipe.name.lowercased()
        guard !(try await takenFlowNames(client)).contains(key) else { throw RecipeFlowError.nameTaken(recipe.name) }
        let id: String
        do { id = try await client.createRecipeFlow(recipe) } catch {
            noteAurralError(error)
            throw Self.recipeError(error, name: recipe.name)
        }
        do { try await client.turnOnRecipeFlow(id) } catch {
            // Made but off: one more try, else say so (an edit turns it on: `runEditedFlow`).
            do { try await client.turnOnRecipeFlow(id) } catch {
                noteAurralError(error)
                afterRecipeFlowChange()
                throw RecipeFlowError.notStarted
            }
        }
        afterRecipeFlowChange()
        return id
    }

    /// Edit flow: the changed fields are sent, then the flow is updated on the server so its songs follow the new
    /// recipe (in the background: the sheet closes at once).
    func updateRecipeFlow(_ flow: AurralFlow, to recipe: FlowRecipe) async throws {
        guard let old = flow.recipe else { throw AurralError.notFound }
        let client = try recipeFlowClient()
        let recipe = Self.prepared(recipe)
        if let problem = recipe.problem { throw RecipeFlowError.invalid(problem) }
        if recipe.name.lowercased() != old.name.lowercased() {
            guard !(try await takenFlowNames(client, except: flow.id)).contains(recipe.name.lowercased()) else {
                throw RecipeFlowError.nameTaken(recipe.name)
            }
        }
        let sent: Bool
        do { sent = try await client.updateRecipeFlow(flow.id, from: old, to: recipe) } catch {
            noteAurralError(error)
            throw Self.recipeError(error, name: recipe.name)
        }
        guard sent else { return }
        let enabled = flow.enabled
        Task { [weak self] in await self?.runEditedFlow(flow.id, enabled: enabled) }
        afterRecipeFlowChange()
    }

    /// How long an edited flow waits for a run already under way before its own (5 s steps).
    nonisolated static let editRunWait: Duration = .seconds(120)

    /// The edited flow is updated on the server: run now (Refresh Flow's start), once any run under way has finished;
    /// a flow that is off (made elsewhere, or a start that failed) is turned on, which runs it.
    func runEditedFlow(_ flowId: String, enabled: Bool) async {
        guard let client = try? recipeFlowClient() else { return }
        if !enabled {
            try? await client.turnOnRecipeFlow(flowId)
            await refreshDiscoverStatus()
            return
        }
        let deadline = ContinuousClock.now + Self.editRunWait
        while ContinuousClock.now < deadline, !Task.isCancelled {
            do {
                try await refreshFlow(flowId)
                return
            } catch AurralError.runActive {
                try? await Task.sleep(for: .seconds(5))
            } catch {
                noteAurralError(error)
                return
            }
        }
    }

    /// Delete flow: Aurral queues the delete (its songs go, except ones another playlist or flow uses); the flow leaves
    /// Your flows now.
    func deleteRecipeFlow(_ flow: AurralFlow) async throws {
        let client = try recipeFlowClient()
        do { try await client.deleteRecipeFlow(flow.id) } catch {
            noteAurralError(error)
            throw error
        }
        discover.deletingFlowIds.insert(flow.id)
        afterRecipeFlowChange()
    }

    /// Simple's Focus without a tag or a similar artist uses recent listening (Aurral's rule for Focus).
    nonisolated static func prepared(_ recipe: FlowRecipe) -> FlowRecipe {
        var recipe = recipe
        recipe.name = recipe.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if recipe.sources.contains(.focus), recipe.tags.isEmpty, recipe.relatedArtists.isEmpty { recipe.recentListening = true }
        return recipe
    }

    nonisolated static func recipeError(_ error: Error, name: String) -> Error {
        if case AurralError.http(status: 400)? = error as? AurralError { return RecipeFlowError.nameTaken(name) }
        return error
    }

    /// Discover and Home read again behind the change (a new flow's playlist appears as the server publishes it).
    private func afterRecipeFlowChange() {
        Task { [weak self] in
            await self?.refreshDiscover(force: true)
            self?.homeFeedSlot?.sectionsChanged([.discover])
        }
    }
}

/// A recipe flow's background download, as Your flows shows it.
enum RecipeFlowDownload: Equatable {
    case gettingSongs
    case downloading(done: Int, total: Int)

    var text: String {
        switch self {
        case .gettingSongs: "Getting songs\u{2026}"
        case .downloading(let done, let total): "Downloading \(done) of \(total)\u{2026}"
        }
    }
}

/// Why a recipe flow change didn't go through (beyond the server's own errors).
enum RecipeFlowError: Error, Equatable {
    case invalid(String)
    case nameTaken(String)
    /// Made, but it couldn't be turned on (its songs didn't start).
    case notStarted

    var message: String {
        switch self {
        case .invalid(let problem): problem
        case .nameTaken(let name): "You already have a flow or playlist called \u{201C}\(name)\u{201D}."
        case .notStarted: "Your flow was made, but its songs couldn\u{2019}t start downloading. Edit it to try again."
        }
    }
}

/// Round 16: the recipe editor's words (no service name).
enum RecipeFlowCopy {
    static let defaultName = "My flow"
    static let yourFlows = "Your flows"
    static let newFlow = "New flow"
    static let editFlow = "Edit flow"
    static let deleteFlow = "Delete flow"
    static let deleteQuestion = "Delete this flow?"
    static let deleteNote = "The flow and its playlist go. Songs it downloaded are deleted unless another of your flows or playlists uses them, even if a playlist you made still has them. Songs you already had stay."
    static let simple = "Simple"
    static let advanced = "Advanced"
    static let name = "Name"
    static let sources = "Sources"
    static let sourcesNote = "Where the songs come from. Each source picked gets an equal share."
    static let sharesNote = "Each source\u{2019}s share of the songs."
    static let deeperCuts = "Deeper cuts"
    static let deeperCutsNote = "Less obvious songs from the same artists."
    static let updates = "Updates"
    static let time = "Time"
    static let tags = "Tags"
    static let addTag = "Add a tag"
    static let excludeTags = "Leave out tags"
    static let addExcludeTag = "Add a tag to leave out"
    static let similarTo = "Similar to"
    static let addArtist = "Add an artist"
    static let recentListening = "Use my recent listening"
    static let autoDownload = "Download automatically"
    static let released = "Released between"
    static let from = "From"
    static let to = "To"
    static let anyYear = "Any"
    static let usesAdvanced = "This flow uses advanced settings. Change them under Advanced."
    static let createNote = "Its songs start downloading as soon as it\u{2019}s made."
    static let editNote = "Saving updates the flow\u{2019}s songs to the new recipe."
    static let create = "Create"
    static let save = "Save"
    static let cancel = "Cancel"

    static func songs(_ n: Int) -> String { n == 1 ? "1 song" : "\(n) songs" }

    static func source(_ source: FlowSource) -> String {
        switch source {
        case .discover: "Discover"
        case .mix: "Library"
        case .trending: "Trending"
        case .focus: "Focus"
        case .newReleases: "New releases"
        }
    }

    /// Sunday first, as the server numbers days.
    static let dayLetters = ["S", "M", "T", "W", "T", "F", "S"]
    static let dayNames = ["Sundays", "Mondays", "Tuesdays", "Wednesdays", "Thursdays", "Fridays", "Saturdays"]

    static func hour(_ h: Int) -> String {
        var c = DateComponents()
        c.hour = h
        let date = Calendar.current.date(from: c) ?? Date()
        return date.formatted(date: .omitted, time: .shortened)
    }

    /// "Fridays at 12:00 AM", "Mondays, Fridays at 9:00 AM", "Every day at 6:00 PM".
    static func schedule(_ recipe: FlowRecipe) -> String {
        let days = recipe.scheduleDays.sorted()
        let when = days.count == 7 ? "Every day" : days.map { dayNames[$0] }.joined(separator: ", ")
        return "\(when) at \(hour(recipe.scheduleHour))"
    }

    /// A flow's one-line summary in Your flows: "30 songs · Discover, Trending".
    static func summary(_ recipe: FlowRecipe) -> String {
        "\(songs(recipe.size)) \u{00B7} " + recipe.sources.map(source).joined(separator: ", ")
    }
}
