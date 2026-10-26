import Foundation
import Testing
@testable import MagpieCore
import MagpieTestSupport

@Suite struct EndpointTests {
    @Test func keepsBasePath() {
        let base = URL(string: "https://h/navidrome")!
        let endpoint = ServerEndpoint(bases: [base])
        #expect(endpoint.url(base, path: "rest/ping").absoluteString == "https://h/navidrome/rest/ping")
        #expect(endpoint.url(base, path: "/rest/ping").absoluteString == "https://h/navidrome/rest/ping")
        let slashBase = URL(string: "https://h/navidrome/")!
        #expect(endpoint.url(slashBase, path: "rest/ping").absoluteString == "https://h/navidrome/rest/ping")
    }

    @Test func encodesPathSegments() {
        let base = URL(string: "https://h/navidrome")!
        let endpoint = ServerEndpoint(bases: [base])
        #expect(endpoint.url(base, path: "rest/my song.mp3").absoluteString == "https://h/navidrome/rest/my%20song.mp3")
        #expect(endpoint.url(base, path: "a?b#c/d").absoluteString == "https://h/navidrome/a%3Fb%23c/d")
        #expect(endpoint.url(base, path: "Beyoncé/日本").absoluteString
            == "https://h/navidrome/Beyonc%C3%A9/%E6%97%A5%E6%9C%AC")
        #expect(endpoint.url(base, path: "x", query: [URLQueryItem(name: "q", value: "1")]).absoluteString
            == "https://h/navidrome/x?q=1")
    }

    @Test func keepsPortAndRootBase() {
        let base = URL(string: "http://192.168.1.5:4533")!
        let endpoint = ServerEndpoint(bases: [base])
        #expect(endpoint.url(base, path: "rest/ping").absoluteString == "http://192.168.1.5:4533/rest/ping")
    }

    @Test func encodesQuery() {
        let base = URL(string: "https://h/navidrome")!
        let endpoint = ServerEndpoint(bases: [base])
        let url = endpoint.url(base, path: "rest/search3", query: [URLQueryItem(name: "query", value: "a&b")])
        #expect(url.absoluteString == "https://h/navidrome/rest/search3?query=a%26b")
        let plus = endpoint.url(base, path: "x", query: [URLQueryItem(name: "q", value: "a+b c=d")])
        #expect(plus.absoluteString == "https://h/navidrome/x?q=a%2Bb%20c%3Dd")
    }

    @Test func failoverOrder() async {
        let a = URL(string: "https://a/")!
        let b = URL(string: "https://b/")!
        let endpoint = ServerEndpoint(bases: [a, b])
        let probed = Probed()
        let result = await firstReachable(endpoint) { url in
            await probed.add(url)
            return url == b
        }
        #expect(result == b)
        #expect(await probed.urls == [a, b])
        let none = await firstReachable(endpoint) { _ in false }
        #expect(none == nil)
    }

    @Test func mockTransportRoutesAndRecords() async throws {
        let mock = MockTransport()
        mock.stub(method: "GET", pathSuffix: "rest/ping", status: 200, body: Data("ok".utf8), headers: ["X-A": "1"])
        var req = URLRequest(url: URL(string: "https://h/navidrome/rest/ping?u=x")!)
        req.httpMethod = "GET"
        let (data, resp) = try await mock.send(req)
        #expect(data == Data("ok".utf8))
        #expect(resp.statusCode == 200)
        #expect(resp.value(forHTTPHeaderField: "X-A") == "1")
        #expect(mock.requests.count == 1)
        let miss = URLRequest(url: URL(string: "https://h/other")!)
        let (_, missResp) = try await mock.send(miss)
        #expect(missResp.statusCode == 404)
    }
}

actor Probed {
    var urls: [URL] = []
    func add(_ u: URL) { urls.append(u) }
}
