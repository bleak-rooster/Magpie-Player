import Foundation
import MagpieCore
import os
import Testing

/// S14 L4 (D119): an artist picture's host (Lidarr's answer names it) is looked up first, and refused when any of its
/// addresses is on the owner's network (private, loopback, link-local, CGNAT, unique-local) or isn't a usable public
/// one. The Cover Art Archive's fixed hosts aren't looked up. Lookups are injected here: no DNS, nothing sent.
@MainActor @Suite(.serialized) struct S14OutsideArtAddressTests {
    nonisolated static func v4(_ s: String) -> [UInt8] { s.split(separator: ".").map { UInt8($0)! } }

    @Test func addressClasses() {
        for s in ["10.1.2.3", "127.0.0.1", "169.254.1.1", "172.16.0.1", "172.31.255.255", "192.168.1.2", "100.64.0.1",
                  "100.127.255.254", "0.0.0.0", "224.0.0.1", "255.255.255.255", "192.0.0.8"] {
            #expect(!OutsideArtPolicy.isPublicAddress(Self.v4(s)), "\(s)")
        }
        for s in ["8.8.8.8", "151.101.1.1", "172.32.0.1", "100.128.0.1", "192.169.0.1", "1.1.1.1"] {
            #expect(OutsideArtPolicy.isPublicAddress(Self.v4(s)), "\(s)")
        }
        func v6(_ s: String) -> [UInt8] {
            var a = in6_addr()
            #expect(inet_pton(AF_INET6, s, &a) == 1)
            return withUnsafeBytes(of: &a) { Array($0) }
        }
        for s in ["::1", "::", "fe80::1", "fd00::1", "fc12::1", "ff02::1", "::ffff:192.168.1.2", "::ffff:127.0.0.1",
                  "64:ff9b::a00:1"] {
            #expect(!OutsideArtPolicy.isPublicAddress(v6(s)), "\(s)")
        }
        for s in ["2606:4700::1111", "2a04:4e42::81", "::ffff:8.8.8.8", "64:ff9b::808:808"] {
            #expect(OutsideArtPolicy.isPublicAddress(v6(s)), "\(s)")
        }
        #expect(!OutsideArtPolicy.isPublicAddress([1, 2, 3]), "not an address")
    }

    static func transport(_ resolve: @escaping @Sendable (String) -> [[UInt8]]?) -> OutsideArtTransport {
        let config = OutsideArtTransport.configuration
        config.protocolClasses = [AddressStub.self]
        return OutsideArtTransport(configuration: config, resolve: resolve)
    }

    @Test func anArtistHostOnTheOwnersNetworkIsRefusedBeforeAnythingIsSent() async throws {
        let url = URL(string: "https://assets.fanart.example/poster.jpg")!   // into StubProtocol only
        for addresses in [[Self.v4("192.168.1.2")], [Self.v4("151.101.1.1"), Self.v4("10.0.0.5")], [], nil] {
            AddressStub.reset()
            await #expect(throws: URLError.self) {
                _ = try await Self.transport { _ in addresses }.send(URLRequest(url: url))
            }
            #expect(AddressStub.seen.isEmpty, "nothing sent for \(String(describing: addresses))")
        }
        AddressStub.reset()
        let asked = OSAllocatedUnfairLock(initialState: [String]())
        let (_, response) = try await Self.transport { host in
            asked.withLock { $0.append(host) }
            return [Self.v4("151.101.1.1")]
        }.send(URLRequest(url: url))
        #expect(response.statusCode == 200 && AddressStub.seen == [url])
        #expect(asked.withLock { $0 } == ["assets.fanart.example"])
    }

    @Test func theCoverArtArchiveIsNotLookedUp() async throws {
        let url = URL(string: "https://coverartarchive.org/release-group/\(OutsideArtTests.rg.rawValue)/front-250")!
        AddressStub.reset()
        let (_, response) = try await Self.transport { _ in Issue.record("looked up"); return nil }.send(URLRequest(url: url))
        #expect(response.statusCode == 200)
    }
}

/// Answers every request 200 with a small PNG, recording the URLs asked (its own state: suites run side by side).
final class AddressStub: URLProtocol, @unchecked Sendable {
    private static let state = OSAllocatedUnfairLock(initialState: [URL]())
    static func reset() { state.withLock { $0 = [] } }
    static var seen: [URL] { state.withLock { $0 } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url else { return }
        Self.state.withLock { $0.append(url) }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "image/png"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: OutsideArtHardeningTests.image(width: 4, height: 4, type: .png))
        client?.urlProtocolDidFinishLoading(self)
    }
}
