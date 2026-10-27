import Foundation
import MagpieCore
import MagpieTestSupport
import Testing

/// Task H1: the IT helper that shares one dev-Navidrome login across IT clients and test processes.
@Suite struct SharedLoginTransportTests {
    static func login(_ body: String = #"{"username":"admin","password":"x"}"#) -> URLRequest {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:4533/auth/login")!)
        request.httpMethod = "POST"
        request.httpBody = Data(body.utf8)
        return request
    }

    @Test func oneLoginIsSharedUntilTheServerTurnsItDown() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "magpie-shared-login-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let inner = MockTransport()
        inner.stub(method: "POST", pathSuffix: "/auth/login", body: Data(#"{"token":"jwt"}"#.utf8))
        inner.stub(pathSuffix: "/api/song", status: 401)
        let a = SharedLoginTransport(inner: inner, directory: dir), b = SharedLoginTransport(inner: inner, directory: dir)
        let logins = { inner.requests.filter { $0.url?.path == "/auth/login" }.count }

        let (first, _) = try await a.send(Self.login())
        let (second, response) = try await b.send(Self.login(#"{"password":"x","username":"admin"}"#))   // key order
        #expect(logins() == 1 && second == first && response.statusCode == 200)
        _ = try await b.send(Self.login(#"{"username":"listener","password":"y"}"#))
        #expect(logins() == 2, "another account logs in for itself")

        _ = try await a.send(URLRequest(url: URL(string: "http://127.0.0.1:4533/api/song")!))   // 401
        _ = try await b.send(Self.login())
        #expect(logins() == 3, "a turned-down login is not handed out again")
    }

    static func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "magpie-shared-login-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// G0, structurally: whatever a test hands it, the transport only ever talks to 127.0.0.1 or localhost.
    @Test func refusesEveryNonLocalHost() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let inner = MockTransport()
        inner.stub(method: "POST", pathSuffix: "/auth/login", body: Data(#"{"token":"jwt"}"#.utf8))
        inner.stub(pathSuffix: "/rest/ping.view", body: Data("{}".utf8))
        let transport = SharedLoginTransport(inner: inner, directory: dir)
        for address in ["https://music.example.com", "http://192.168.1.20:4533", "http://127.0.0.2:4533",
                        "http://localhost.example.com:4533", "http://[::1]:4533", "http://127.0.0.1.nip.io:4533"] {
            var login = Self.login()
            login.url = URL(string: address + "/auth/login")
            await #expect(throws: SharedLoginTransport.NotLocal.self, "\(address)") { _ = try await transport.send(login) }
            await #expect(throws: SharedLoginTransport.NotLocal.self, "\(address)") {
                _ = try await transport.send(URLRequest(url: URL(string: address + "/rest/ping.view")!))
            }
        }
        #expect(inner.requests.isEmpty, "nothing reached any server")
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".json") }.isEmpty)
        _ = try await transport.send(URLRequest(url: URL(string: "http://localhost:4533/rest/ping.view")!))
        #expect(inner.requests.count == 1)
    }

    /// Expired kept logins and stale lock files are deleted on use; the file name carries no hash an outsider could
    /// recompute from the password (a random salt kept beside it, per folder).
    @Test func sweepsExpiredFilesAndSaltsTheKey() async throws {
        let dir = try Self.tempDir(), other = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(at: other) }
        let old = Date().addingTimeInterval(-3_600)
        let expired = dir.appending(path: "magpie-it-login-127.0.0.1_4533-abc.json")
        let staleLock = dir.appending(path: "magpie-it-login-127.0.0.1_4533-abc.json.lock")
        let unrelated = dir.appending(path: "something-else.json")
        for file in [expired, staleLock, unrelated] {
            FileManager.default.createFile(atPath: file.path, contents: Data("{}".utf8))
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: file.path)
        }
        let inner = MockTransport()
        inner.stub(method: "POST", pathSuffix: "/auth/login", body: Data(#"{"token":"jwt"}"#.utf8))
        _ = try await SharedLoginTransport(inner: inner, lifetime: 600, directory: dir).send(Self.login())
        _ = try await SharedLoginTransport(inner: inner, lifetime: 600, directory: other).send(Self.login())
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(!names.contains(expired.lastPathComponent) && !names.contains(staleLock.lastPathComponent))
        #expect(names.contains(unrelated.lastPathComponent), "only its own files")
        let kept = { (d: URL) in
            try FileManager.default.contentsOfDirectory(atPath: d.path).filter { $0.hasPrefix("magpie-it-login-") && $0.hasSuffix(".json") }
        }
        #expect(try kept(dir).count == 1 && kept(other).count == 1)
        #expect(try kept(dir) != kept(other), "a different salt per folder: the name doesn't follow from the login")
    }
}
