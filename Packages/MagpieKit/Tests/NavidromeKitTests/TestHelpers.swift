import Foundation
import MagpieCore
import MagpieTestSupport
import os
@testable import NavidromeKit

enum Fixtures {
    static func data(_ name: String) -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "navidrome"),
              let data = try? Data(contentsOf: url) else {
            fatalError("Missing fixture \(name).json")
        }
        return data
    }

    static func json(_ name: String) -> Any {
        try! JSONSerialization.jsonObject(with: data(name))
    }
}

let testBase = URL(string: "https://music.example/navidrome")!
let testCredentials = NavidromeCredentials(username: "admin", password: "hunter2-not-real")

/// A client wired to a MockTransport that answers ping and login from fixtures.
func makeClient(bases: [URL] = [testBase], transport: MockTransport = MockTransport()) -> (NavidromeClient, MockTransport) {
    transport.stub(pathSuffix: "/rest/ping", body: Fixtures.data("getOpenSubsonicExtensions"))
    transport.stub(method: "POST", pathSuffix: "/auth/login", body: Fixtures.data("login"))
    let client = NavidromeClient(endpoint: ServerEndpoint(bases: bases), credentials: testCredentials,
                                 transport: transport)
    return (client, transport)
}

func queryItems(_ request: URLRequest) -> [URLQueryItem] {
    URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
}

func queryValue(_ request: URLRequest, _ name: String) -> String? {
    queryItems(request).first { $0.name == name }?.value
}

/// Delays `/auth/login` once at least one 401 has been seen, until `waitFor` of them have been recorded.
struct LoginGateTransport: HTTPTransport {
    let inner: MockTransport
    let rejected: OSAllocatedUnfairLock<Int>
    let waitFor: Int

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if request.url?.path.hasSuffix("/auth/login") == true, rejected.withLock({ $0 }) > 0 {
            for _ in 0..<2000 where rejected.withLock({ $0 }) < waitFor {
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        return try await inner.send(request)
    }
}
