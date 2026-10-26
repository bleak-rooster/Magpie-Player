import Foundation
import Testing
import os
import MagpieCore
@testable import LidarrKit

/// Passes requests to a real transport and remembers each method + path.
final class RecordingTransport: HTTPTransport {
    private let inner: HTTPTransport
    private let log = OSAllocatedUnfairLock(initialState: [String]())

    init(_ inner: HTTPTransport) { self.inner = inner }

    var calls: [String] { log.withLock { $0 } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        log.withLock { $0.append("\(request.httpMethod ?? "GET") \(request.url?.path ?? "")") }
        return try await inner.send(request)
    }
}

extension LidarrDevStack {
    /// The dev stack's Lidarr root folders, as `dev/bootstrap.sh` creates them.
    static let devRoots: Set<String> = ["/music/library", "/music/samples"]

    /// G0 for write tests: on top of `load()` (local host + `.env.local` dev marker), the server itself must
    /// look like the dev stack (its root folders are exactly the bootstrap ones). Aborts otherwise.
    static func writableClient(_ transport: HTTPTransport) async throws -> LidarrClient {
        let cfg = try load()
        let client = LidarrClient(base: cfg.url, apiKey: cfg.apiKey, transport: transport)
        let status = try await client.status()
        let roots = Set(try await client.rootFolders().map(\.path))
        guard status.instanceName == "Lidarr", roots == devRoots else { throw Failure.notDevStack }
        return client
    }
}

@Suite(.enabled(if: LidarrDevStack.enabled, "set MAGPIE_IT=1 (scripts/it.sh) to run integration tests"))
struct ProvisionIT {
    /// Writes to the dev stack's Lidarr: creates Magpie's profiles and tags if they are missing.
    @Test func onDevStack() async throws {
        let recorder = RecordingTransport(URLSessionTransport())
        let client = try await LidarrDevStack.writableClient(recorder)
        let suite = "magpie-it-\(UUID().uuidString)"
        let logURL = FileManager.default.temporaryDirectory.appending(path: "magpie-it-\(UUID().uuidString)/log.json")
        let gate = LidarrWriteGate(client: client, logURL: logURL, defaultsSuite: suite)
        await gate.setEnabled(true)
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }

        let first = try await Provisioner().ensure(gate: gate, client: client)
        #expect(Set(first.created).isSubset(of: Set(Provisioner.qualityProfileNames + Provisioner.metadataProfileNames
                                                   + [Provisioner.magpieTag, Provisioner.findTag])))
        #expect(recorder.calls.allSatisfy { $0.hasPrefix("GET ") || $0.hasPrefix("POST ") })

        let before = recorder.calls.count
        let second = try await Provisioner().ensure(gate: gate, client: client)
        #expect(second.created.isEmpty)
        #expect(recorder.calls.dropFirst(before).allSatisfy { $0.hasPrefix("GET ") })   // no POST on the second run
        #expect(second == ProvisionResult(fastStartProfileId: first.fastStartProfileId, losslessProfileId: first.losslessProfileId,
                                          findsMetadataProfileId: first.findsMetadataProfileId,
                                          albumsEPsMetadataProfileId: first.albumsEPsMetadataProfileId,
                                          magpieTagId: first.magpieTagId, findTagId: first.findTagId, created: []))
        #expect(await LidarrAudit.run(client).hasMagpieProfiles)
        #expect(await gate.changeLog().count == first.created.count)
    }
}
