import Foundation
import MagpieCore
import MagpieTestSupport
import os
import Testing
@testable import AurralKit

/// Round 14 security fixes (S14).
@Suite struct S14SecurityTests {
    /// Answers every call itself (never sends anything) and records the cap each call asked for.
    final class CapRecorder: HTTPTransport, @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock(initialState: (caps: [Int?](), status: 200, body: Data()))
        var caps: [Int?] { lock.withLock { $0.caps } }
        init(status: Int = 200, body: Data = Data("{}".utf8)) { lock.withLock { $0.status = status; $0.body = body } }

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            try answer(request, cap: nil)
        }

        func send(_ request: URLRequest, maxBytes: Int) async throws -> (Data, HTTPURLResponse) {
            try answer(request, cap: maxBytes)
        }

        private func answer(_ request: URLRequest, cap: Int?) throws -> (Data, HTTPURLResponse) {
            let (status, body) = lock.withLock { $0.caps.append(cap); return ($0.status, $0.body) }
            if let cap, body.count > cap { throw ResponseTooLarge() }
            return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }

    let base = URL(string: "http://127.0.0.1:3901")!

    // MARK: - M1 (D115): every Aurral answer is capped

    @Test func everyKeyedCallAsksForTheCap() async throws {
        let transport = CapRecorder(body: Data(#"{"appVersion":"2.13.0"}"#.utf8))
        let login = AurralLogin(token: "T", expiresAt: nil, user: AurralUser(id: 1, username: "u", role: "admin"))
        let client = AurralClient(base: base, session: AurralSession(username: "u", password: "p", login: login),
                                  transport: transport)
        _ = try await client.health()
        _ = try? await client.status()
        _ = try? await AurralClient.signIn(base: base, username: "u", password: "p", transport: transport)
        #expect(!transport.caps.isEmpty)
        #expect(transport.caps.allSatisfy { $0 == AurralClient.maxResponseBytes }, "\(transport.caps)")
        #expect(AurralClient.maxResponseBytes == 8 * 1024 * 1024)
    }

    @Test func oversizedAnswerIsDecodingError() async throws {
        let transport = CapRecorder(body: Data(count: AurralClient.maxResponseBytes + 1))
        let login = AurralLogin(token: "T", expiresAt: nil, user: AurralUser(id: 1, username: "u", role: "admin"))
        let client = AurralClient(base: base, session: AurralSession(username: "u", password: "p", login: login),
                                  transport: transport)
        await #expect(throws: AurralError.decoding) { _ = try await client.health() }
    }

    // MARK: - L1 (D117): a 403 on login isn't a wrong password

    @Test func forbiddenLoginIsNotBadLogin() async throws {
        let transport = CapRecorder(status: 403, body: Data(#"{"error":"Forbidden"}"#.utf8))
        await #expect(throws: AurralError.http(status: 403)) {
            _ = try await AurralClient.signIn(base: base, username: "u", password: "p", transport: transport)
        }
    }

    @Test func forbiddenReLoginKeepsThePasswordAndBacksOff() async throws {
        let transport = CapRecorder(status: 403, body: Data(#"{"error":"Forbidden"}"#.utf8))
        let refused = OSAllocatedUnfairLock(initialState: 0)
        let session = AurralSession(username: "u", password: "p", login: nil, onRefused: { refused.withLock { $0 += 1 } })
        let client = AurralClient(base: base, session: session, transport: transport)
        await #expect(throws: AurralError.http(status: 403)) { _ = try await client.status() }
        #expect(refused.withLock { $0 } == 0, "the saved password is kept")
        #expect(await session.needsSignIn == false)
        let sent = transport.caps.count
        await #expect(throws: AurralError.http(status: 403)) { _ = try await client.status() }
        #expect(transport.caps.count == sent, "backed off: no second login straight away")
    }

    // MARK: - L3 (D118): the picture mapping is kept out of backups and goes with the account

    @Test func theMappingIsExcludedFromBackupAndErased() async throws {
        let stub = StubAurral()
        stub.useAurral213()
        let client = AurralClient(base: stub.base, session: stub.signedInSession(), transport: stub)
        let directory = FileManager.default.temporaryDirectory.appending(path: "s14-image-proxy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let proxy = AurralImageProxy(base: stub.base, directory: directory, openTransport: stub)
        _ = try await client.trending()
        let art = try #require(AurralImage(AurralImageProxyTests.songArt))
        #expect(await proxy.imageData(for: art, client: client) != nil)
        let file = directory.appending(path: proxy.server + ".json")
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(try file.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        #expect(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)

        await proxy.erase()
        #expect(!FileManager.default.fileExists(atPath: file.path))
        // Erased for good: a later picture is neither looked up in nor written to the mapping.
        let posts = stub.imageProxySources.count
        _ = await proxy.imageData(for: art, client: client)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(stub.imageProxySources.count == posts + 1, "asked afresh, not from the erased mapping")
    }
}
