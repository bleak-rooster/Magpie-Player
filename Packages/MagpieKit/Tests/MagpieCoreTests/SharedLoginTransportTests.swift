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
}
