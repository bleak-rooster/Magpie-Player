import Foundation
import MagpieCore
import MagpieTestSupport
import Testing
@testable import AurralKit

/// Round 16 (owner, 2026-11-05): the user's own flows from a recipe. Aurral 2.13: `POST /api/playlists/flows` makes the
/// flow off, `PUT …/:id/enabled {enabled: true}` turns it on (its first run), `PUT …/:id` takes the changed fields,
/// `DELETE …/:id` queues the delete.
@Suite struct RecipeFlowTests {
    let stub: StubAurral
    let client: AurralClient

    init() {
        stub = StubAurral()
        stub.useAurral213()
        client = AurralClient(base: stub.base, session: stub.signedInSession(), transport: stub)
    }

    static func recipe(_ name: String = "My flow") -> FlowRecipe {
        var r = FlowRecipe(name: name, size: 12, tags: ["indie"], scheduleDays: [1, 5], scheduleHour: 9)
        r.setSources([.discover, .trending])
        return r
    }

    @Test func theFourRoutesAndNothingNear() {
        #expect(AurralRoute.route(method: "POST", path: "api/playlists/flows") == .recipeFlowCreate)
        #expect(AurralRoute.route(method: "PUT", path: "api/playlists/flows/flow-1/enabled") == .recipeFlowTurnOn)
        #expect(AurralRoute.route(method: "PUT", path: "api/playlists/flows/flow-1") == .recipeFlowUpdate)
        #expect(AurralRoute.route(method: "DELETE", path: "api/playlists/flows/flow-1") == .recipeFlowDelete)
        for (method, path) in [("GET", "api/playlists/flows"), ("PUT", "api/playlists/flows"), ("DELETE", "api/playlists/flows"),
                               ("POST", "api/playlists/flows/flow-1"), ("GET", "api/playlists/flows/flow-1"),
                               ("PATCH", "api/playlists/flows/flow-1"), ("POST", "api/playlists/flows/flow-1/enabled"),
                               ("DELETE", "api/playlists/flows/flow-1/enabled"), ("PUT", "api/playlists/flows/../settings"),
                               ("POST", "api/playlists/flows/flow-1/static-playlist"),
                               ("GET", "api/playlists/flows/flow-1/lidarr-import-list"), ("DELETE", "api/playlists/flows/a b")] {
            #expect(!AurralRoute.isAllowed(method: method, path: path), "\(method) \(path)")
        }
    }

    @Test func createSendsTheRecipeAndTurnsItOn() async throws {
        let id = try await client.createRecipeFlow(Self.recipe())
        try await client.turnOnRecipeFlow(id)
        #expect(stub.asked == ["POST /api/playlists/flows", "PUT /api/playlists/flows/\(id)/enabled"])
        let fields = try #require(stub.recipeFlowFields(id))
        #expect(fields["enabled"] as? Bool == true)
        #expect(fields["scheduleTime"] as? String == "09:00")
        #expect(fields["scheduleDays"] as? [Int] == [1, 5])
        #expect(fields["tags"] as? [String] == ["indie"])
        #expect((fields["mix"] as? [String: Int]) == ["discover": 50, "mix": 0, "trending": 50, "focus": 0, "newReleases": 0])
        #expect(fields["autoDownload"] as? Bool == true)
        let status = try await client.status()
        let flow = try #require(status.flows.first { $0.id == id })
        #expect(flow.recipe?.sources == [.discover, .trending])
        #expect(flow.recipe?.scheduleHour == 9 && flow.recipe?.tags == ["indie"])
    }

    @Test func aTakenNameIsRefused() async throws {
        _ = try await client.createRecipeFlow(Self.recipe("Mine"))
        await #expect(throws: AurralError.http(status: 400)) { try await client.createRecipeFlow(Self.recipe("mine")) }
    }

    @Test func anEditSendsOnlyTheChangedFields() async throws {
        let id = try await client.createRecipeFlow(Self.recipe())
        var new = Self.recipe()
        new.deepDive = true
        new.yearFrom = 2015
        #expect(try await client.updateRecipeFlow(id, from: Self.recipe(), to: new))
        let body = try #require(stub.requests.last?.httpBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect(Set(body.keys) == ["deepDive", "yearFrom"])
        #expect(stub.recipeFlowFields(id)?["deepDive"] as? Bool == true)
        // Clearing a year sends null; nothing changed sends nothing.
        var cleared = new
        cleared.yearFrom = nil
        #expect(new.changes(from: new).isEmpty)
        #expect(cleared.changes(from: new)["yearFrom"] is NSNull)
        let before = stub.asked.count
        #expect(try await !client.updateRecipeFlow(id, from: new, to: new))
        #expect(stub.asked.count == before)
    }

    @Test func deleteIsQueuedAndAGoneFlowIsDeleted() async throws {
        let id = try await client.createRecipeFlow(Self.recipe())
        try await client.deleteRecipeFlow(id)
        #expect(stub.asked.last == "DELETE /api/playlists/flows/\(id)")
        _ = try await client.status()
        _ = try await client.status()
        #expect(try await client.status().flows.allSatisfy { $0.id != id })
        try await client.deleteRecipeFlow(id)   // 404: already gone
    }

    @Test func refusedUnsent() async throws {
        var bad = Self.recipe()
        bad.shares = [:]
        #expect(bad.problem != nil)
        await #expect(throws: AurralError.self) { try await client.createRecipeFlow(bad) }
        var focus = Self.recipe()
        focus.setSources([.focus])
        focus.tags = []
        #expect(focus.problem != nil)
        focus.recentListening = true
        #expect(focus.problem == nil)
        await #expect(throws: AurralError.self) { try await client.deleteRecipeFlow("../settings") }
        #expect(stub.asked.isEmpty)
    }

    @Test func simpleSharesAndAdvancedDetection() {
        var r = FlowRecipe(name: "x")
        r.setSources([.discover, .mix, .trending])
        #expect(r.shares.values.reduce(0, +) == 100 && !r.hasUnevenShares && !r.usesAdvanced)
        r.shares[.discover] = 80
        #expect(r.hasUnevenShares && r.usesAdvanced)
    }
}
