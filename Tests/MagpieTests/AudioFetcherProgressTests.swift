import Foundation
import MagpieCore
import Synchronization
import Testing
@testable import Magpie

/// Serves the fetcher's requests in-process (no network, G0): `/song` sends 400 kB in four slow chunks with its length,
/// `/hop` redirects to another origin, and any request to that origin is recorded.
private final class StubProtocol: URLProtocol, @unchecked Sendable {
    static let otherOriginRequests = Mutex(0)
    static let size = 400_000

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let client else { return }
        if url.host() == "other.example" {
            Self.otherOriginRequests.withLock { $0 += 1 }
            client.urlProtocol(self, didFailWithError: URLError(.cancelled))
            return
        }
        if url.path == "/hop" {
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1",
                                           headerFields: ["Location": "http://other.example/song"])!
            client.urlProtocol(self, wasRedirectedTo: URLRequest(url: URL(string: "http://other.example/song")!),
                               redirectResponse: response)
            client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client.urlProtocolDidFinishLoading(self)
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "audio/mpeg", "Content-Length": "\(Self.size)"])!
        client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        DispatchQueue.global().async {
            for _ in 0..<4 {
                Thread.sleep(forTimeInterval: 0.2)
                client.urlProtocol(self, didLoad: Data(count: Self.size / 4))
            }
            client.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

/// Review M8: the real fetcher reports progress from its URLSession task, and its task delegate keeps the same-origin
/// redirect rule.
@Suite(.serialized) struct AudioFetcherProgressTests {
    private func fetcher() -> URLSessionAudioFetcher {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return URLSessionAudioFetcher(session: SameOriginRedirects.session(configuration: config))
    }

    @Test func reportsTaskProgressWhileDownloading() async throws {
        let reports = Mutex<[(Int64, Int64)]>([])
        let fetched = try await fetcher().fetch(URL(string: "http://127.0.0.1:4533/song")!, allowsCellular: true) {
            received, expected in reports.withLock { $0.append((received, expected)) }
        }
        defer { try? FileManager.default.removeItem(at: fetched.file) }
        let seen = reports.withLock { $0 }
        #expect(!seen.isEmpty, "progress arrived while the 0.8 s download ran")
        #expect(seen.contains { $0.0 > 0 && $0.0 < Int64(StubProtocol.size) }, "part-way progress: \(seen)")
        #expect(seen.allSatisfy { $0.1 == Int64(StubProtocol.size) }, "the expected size is the length: \(seen)")
        #expect(seen.count <= 6, "at most about 4 a second: \(seen.count)")
        let size = try fetched.file.resourceValues(forKeys: [.fileSizeKey]).fileSize
        #expect(size == StubProtocol.size)
    }

    @Test func refusesARedirectToAnotherOrigin() async throws {
        StubProtocol.otherOriginRequests.withLock { $0 = 0 }
        await #expect(throws: URLSessionAudioFetcher.FetchError.self) {
            _ = try await fetcher().fetch(URL(string: "http://127.0.0.1:4533/hop")!, allowsCellular: true) { _, _ in }
        }
        #expect(StubProtocol.otherOriginRequests.withLock { $0 } == 0, "nothing went to the other origin")
    }
}
