import Foundation
import MagpieCore
import MagpieTestSupport
import os
import Testing
@testable import AurralKit

/// Collects what the client logs (the key must never be in it).
final class LogSink: @unchecked Sendable {
    private let lines = OSAllocatedUnfairLock(initialState: [String]())
    var all: [String] { lines.withLock { $0 } }
    var sink: @Sendable (String) -> Void { { [lines] line in lines.withLock { $0.append(line) } } }
}

@Suite struct AurralClientTests {
    let stub = StubAurral()
    let log = LogSink()
    var client: AurralClient { AurralClient(base: stub.base, apiKey: stub.apiKey, transport: stub, log: log.sink) }

    // MARK: - The allow-list

    /// Exactly five calls may be sent; every other one is refused in code, before anything leaves the phone.
    @Test func everyOtherPathIsRefusedAndNothingIsSent() async throws {
        let refused: [(String, String)] = [
            ("GET", "api/settings"), ("GET", "api/settings/playback"), ("GET", "api/auth/api-key"),
            ("POST", "api/auth/api-key"), ("GET", "api/auth/me"), ("GET", "api/discover"), ("POST", "api/discover/refresh"),
            ("DELETE", "api/library/tracks/12"), ("GET", "api/library/tracks/12"), ("POST", "api/library/artists"),
            ("POST", "api/library/downloads/track"), ("GET", "api/health/bootstrap"), ("GET", "api/health/live"),
            ("GET", "api/playlists/jobs/flow-1"), ("GET", "api/playlists/worker/settings"),
            ("PUT", "api/playlists/flows/flow-1/enabled"), ("POST", "api/playlists/flows/flow-1/tracks/job-1/research"),
            ("GET", "api/playlists/flows/flow-1/lidarr-import-list"), ("POST", "api/playlists/reset"),
            ("POST", "api/playlists/research-missing"), ("DELETE", "api/playlists/shared-playlists/p/tracks/j"),
            ("GET", "api/requests"), ("GET", "rest/getPlaylists"),
            // The allowed ones, with the wrong verb or a twisted path.
            ("POST", "api/health"), ("DELETE", "api/playlists/status"), ("PUT", "api/playlists/jobs"),
            ("GET", "api/playlists/start/flow-1"), ("DELETE", "api/playlists/start/flow-1"),
            ("POST", "api/playlists/start/../settings"), ("POST", "api/playlists/start/flow-1/x"),
            ("POST", "api/playlists/start/"), ("POST", "api/playlists/start/a%2Fb"),
            ("GET", "api/library/lookup/not-an-mbid"), ("GET", "api/library/lookup/../../settings"),
            ("GET", "api/library/lookup/0383dadf-2a4e-4d10-a46a-e9e041da8eb3/extra"),
            ("GET", "/api/health"), ("GET", "api//health"), ("GET", "API/HEALTH"), ("GET", "api/health?x=1"),
            ("GET", "https://elsewhere.example/api/health"), ("HEAD", "api/playlists/status"),
        ]
        for (method, path) in refused {
            #expect(!AurralRoute.isAllowed(method: method, path: path), "\(method) \(path)")
            await #expect(throws: AurralError.forbidden("\(method) \(path)"), "\(method) \(path)") {
                _ = try await client.send(method: method, path: path)
            }
        }
        #expect(stub.requests.isEmpty, "nothing was sent")
    }

    @Test func theFiveAllowedCalls() async throws {
        for (method, path) in [("GET", "api/health"), ("GET", "api/playlists/status"), ("GET", "api/playlists/jobs"),
                               ("GET", "api/library/lookup/0383dadf-2a4e-4d10-a46a-e9e041da8eb3"),
                               ("POST", "api/playlists/start/flow-1")] {
            #expect(AurralRoute.isAllowed(method: method, path: path), "\(method) \(path)")
        }
        #expect(AurralRoute.allCases.count == 5)
    }

    /// Never the settings route (it returns every secret in clear), whatever the client is asked to do.
    @Test func neverCallsSettingsAuthOrDiscover() async throws {
        stub.setFlows([.init(id: "flow-1", name: "Discover Weekly")])
        _ = try await client.health()
        _ = try await client.status()
        _ = try await client.jobs()
        _ = try await client.artistLookup(mbid: MBID("0383dadf-2a4e-4d10-a46a-e9e041da8eb3")!)
        _ = try await client.startFlow("flow-1")
        #expect(stub.asked == ["GET /api/health", "GET /api/playlists/status", "GET /api/playlists/jobs",
                               "GET /api/library/lookup/0383dadf-2a4e-4d10-a46a-e9e041da8eb3",
                               "POST /api/playlists/start/flow-1"])
        for line in stub.asked {
            #expect(!line.contains("settings") && !line.contains("auth") && !line.contains("discover"))
        }
    }

    /// A flow id that isn't a plain id is refused (it would name another route).
    @Test func oddFlowIdsAreRefused() async throws {
        for id in ["", "..", "a/b", "../settings", "flow 1", "flow?x=1", "flow#1", String(repeating: "a", count: 101)] {
            await #expect(throws: AurralError.self, "\(id)") { _ = try await client.startFlow(id) }
        }
        #expect(stub.requests.isEmpty)
    }

    // MARK: - The key

    @Test func keySentOnlyAsTheHeaderAndNeverLogged() async throws {
        stub.setFlows([.init(id: "flow-1", name: "Discover Weekly")])
        _ = try await client.status()
        _ = try await client.startFlow("flow-1")
        let unauthorised = AurralClient(base: stub.base, apiKey: "wrong-key-123", transport: stub, log: log.sink)
        await #expect(throws: AurralError.unauthorized) { _ = try await unauthorised.status() }
        for request in stub.requests {
            #expect(request.url?.absoluteString.contains(stub.apiKey) == false, "never in the URL")
            #expect(request.url?.query?.contains("api_key") != true)
        }
        #expect(stub.requests.first?.value(forHTTPHeaderField: "X-Api-Key") == stub.apiKey)
        #expect(log.all.count == 3, "each request is logged once")
        for line in log.all {
            #expect(!line.contains(stub.apiKey) && !line.contains("wrong-key-123"), "logged: \(line)")
        }
        #expect(log.all.allSatisfy { $0.contains("X-Api-Key: \(Redactor.mask)") })
        // Errors carry no key either.
        let error = AurralError.unauthorized
        #expect(!"\(error)".contains("wrong-key-123") && !String(reflecting: error).contains("wrong-key-123"))
        #expect(!String(reflecting: client).contains(stub.apiKey), "the client's description hides the key")
    }

    // MARK: - Reading

    @Test func readsStatusFlowsAndProgress() async throws {
        stub.setFlows([.init(id: "flow-1", name: "Discover Weekly"), .init(id: "flow-2", name: "Trending Mix", enabled: false)])
        stub.setJobs([.init(flowId: "flow-1", artistName: "Low", trackName: "Lullaby", status: "done"),
                      .init(flowId: "flow-1", artistName: "Low", trackName: "Words", status: "failed")])
        let status = try await client.status()
        #expect(status.flows.map(\.name) == ["Discover Weekly", "Trending Mix"])
        #expect(status.flows.map(\.enabled) == [true, false])
        #expect(status.flowStats["flow-1"]?.done == 1)
        #expect(status.flowStats["flow-1"]?.failed == 1)
        #expect(!status.isRunActive(flowId: "flow-1"))
        #expect(status.hint?.message == "Next update in 5 days")
        stub.setRunning("flow-1", true)
        let busy = try await client.status()
        #expect(busy.isRunActive(flowId: "flow-1"))
        #expect(busy.progress(flowId: "flow-1") == AurralProgress(done: 8, total: 20))
    }

    @Test func readsJobs() async throws {
        stub.setJobs([.init(flowId: "flow-1", artistName: "Low", trackName: "Lullaby",
                            artistMbid: "4ad9b3a4-8a3a-4c7f-8b0f-6b7e6f2c0a11", trackMbid: "0383dadf-2a4e-4d10-a46a-e9e041da8eb3",
                            durationMs: 251_000, finalPath: "/data/downloads/aurral/_flows/flow-1/Low/Single/Lullaby.flac")])
        let jobs = try #require(try await client.jobs())
        #expect(jobs.count == 1)
        #expect(jobs[0].flowId == "flow-1")
        #expect(jobs[0].artistMBID == MBID("4ad9b3a4-8a3a-4c7f-8b0f-6b7e6f2c0a11"))
        #expect(jobs[0].trackMBID == MBID("0383dadf-2a4e-4d10-a46a-e9e041da8eb3"))
        #expect(jobs[0].duration == 251)
        #expect(jobs[0].isAurralsOwnFile)
    }

    // MARK: - Version tolerance (built for 2.10.0)

    @Test func versionCheck() async throws {
        #expect(try await client.health().compatibility == .supported("2.10.0"))
        stub.setVersion("2.12.3")
        #expect(try await client.health().compatibility == .newer("2.12.3"))
        stub.setVersion("2.9.1")
        #expect(try await client.health().compatibility == .older("2.9.1"))
        stub.setVersion(nil)
        #expect(try await client.health().compatibility == .unknown)
        #expect(AurralVersion.compatibility("v2.10.4") == .supported("2.10.4"))
        #expect(AurralVersion.compatibility("3.0.0") == .newer("3.0.0"))
        #expect(AurralVersion.compatibility("banana") == .unknown)
    }

    /// A route the server doesn't have (404) is tolerated: jobs read as unknown, lookups as nothing.
    @Test func missingRoutesAreTolerated() async throws {
        stub.setJobsRoute(false)
        #expect(try await client.jobs() == nil)
        let lookup = try await client.artistLookup(mbid: MBID("0383dadf-2a4e-4d10-a46a-e9e041da8eb3")!)
        #expect(lookup?.exists == false)
    }

    /// Answers in unexpected shapes decode leniently: a bad flow is dropped, the rest stay.
    @Test func lenientDecoding() throws {
        let json = Data(#"""
        {"flows":[{"id":"a","name":"Discover Weekly","enabled":"yes"},{"name":"no id"},{"id":7},{"id":"b","name":"Trending"}],
         "flowStats":{"a":{"done":"x","total":3},"b":[]},"operationQueue":{"processing":null,"pending":2},"hint":"text"}
        """#.utf8)
        let status = try AurralStatus.decode(json)
        #expect(status.flows.map(\.id) == ["a", "b"])
        #expect(status.flows[0].enabled == true, "an unreadable enabled reads as on")
        #expect(status.flowStats["a"]?.total == 3)
        #expect(status.flowStats["a"]?.done == nil)
        #expect(status.isRunActive(flowId: "a"), "a pending operation is a run under way")
        #expect(throws: AurralError.decoding) { _ = try AurralStatus.decode(Data("<html>".utf8)) }
        let jobs = try AurralJob.decodeList(Data(#"{"jobs":[{"id":"1","trackName":"T","artistName":"A","playlistId":"a"},{"id":2}]}"#.utf8))
        #expect(jobs.map(\.trackName) == ["T"])
    }

    @Test func errors() async throws {
        stub.setDown(true)
        await #expect(throws: URLError.self) { _ = try await client.status() }
        stub.setDown(false)
        await #expect(throws: AurralError.notFound) { _ = try await client.startFlow("no-such-flow") }
    }
}
