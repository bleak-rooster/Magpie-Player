import CoreGraphics
import Foundation
import ImageIO
import MagpieCore
import MagpieTestSupport
import os
import Testing
import UniformTypeIdentifiers

/// X5 fix round 1: hostile answers. Only the usual cover types at sane sizes are decoded; artist pictures never go to
/// the local network or an IP address; the real transport stops reading past 2 MB and refuses redirects it shouldn't
/// follow (a local URLProtocol stub: nothing reaches the internet).
@MainActor @Suite(.serialized) struct OutsideArtHardeningTests {
    nonisolated static func image(width: Int, height: Int, type: UTType) -> Data {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 0.5, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    @Test func onlyUsualCoverTypesAtSaneSizesAreDecoded() {
        #expect(OutsideArtLoader.decode(Self.image(width: 8, height: 8, type: .png), maxPixel: 100) != nil)
        #expect(OutsideArtLoader.decode(Self.image(width: 8, height: 8, type: .jpeg), maxPixel: 100) != nil)
        #expect(OutsideArtLoader.decode(Self.image(width: 8, height: 8, type: .gif), maxPixel: 100) == nil, "not a cover type")
        #expect(OutsideArtLoader.decode(Self.image(width: 8, height: 8, type: .tiff), maxPixel: 100) == nil)
        #expect(OutsideArtLoader.decode(Self.image(width: OutsideArtPolicy.maxDimension + 1, height: 1, type: .png),
                                        maxPixel: 100) == nil, "an absurd canvas is refused before decoding")
        #expect(OutsideArtLoader.decode(Data("not an image".utf8), maxPixel: 100) == nil)
    }

    @Test func artistPicturesNeverGoToTheLocalNetworkOrAnAddress() {
        let ok = URL(string: "https://assets.fanart.tv/fanart/music/x.jpg")!
        #expect(OutsideArtPolicy.isAllowed(ok, for: .artist(OutsideArtTests.artist)))
        for s in ["https://192.168.1.2/x.jpg", "https://10.0.0.1/x.jpg", "https://[fe80::1]/x.jpg", "https://localhost/x.jpg",
                  "https://nas.local/x.jpg", "https://router.lan/x.jpg", "https://box.home.arpa/x.jpg",
                  "https://printer.internal/x.jpg", "https://intranet/x.jpg"] {
            #expect(!OutsideArtPolicy.isAllowed(URL(string: s)!, for: .artist(OutsideArtTests.artist)), "\(s)")
        }
    }

    // MARK: - The real transport, against a local stub

    static func transport() -> OutsideArtTransport {
        let config = OutsideArtTransport.configuration
        config.protocolClasses = [StubProtocol.self]
        return OutsideArtTransport(configuration: config)
    }

    @Test func theRealTransportStopsReadingPastTwoMegabytes() async throws {
        StubProtocol.reset(.stream(chunk: 256 * 1024, total: 3 * 1024 * 1024))
        let url = URL(string: "https://coverartarchive.org/release-group/\(OutsideArtTests.rg.rawValue)/front-250")!
        await #expect(throws: URLError.self) { _ = try await Self.transport().send(URLRequest(url: url)) }
        #expect(StubProtocol.sentBytes < 3 * 1024 * 1024, "it stopped reading, not buffered and checked after")

        StubProtocol.reset(.declared(length: OutsideArtPolicy.maxBytes + 1))
        await #expect(throws: URLError.self) { _ = try await Self.transport().send(URLRequest(url: url)) }
    }

    @Test func theRealTransportRefusesARedirectItShouldntFollow() async throws {
        let url = URL(string: "https://coverartarchive.org/release-group/\(OutsideArtTests.rg.rawValue)/front-250")!
        StubProtocol.reset(.redirect(to: URL(string: "http://archive.org/plain.jpg")!))
        let refused = try? await Self.transport().send(URLRequest(url: url))
        #expect(refused?.1.statusCode != 200)
        #expect(StubProtocol.seen == [url], "the plain-http target was never asked")

        StubProtocol.reset(.redirect(to: URL(string: "https://elsewhere.example/x.jpg")!))
        let elsewhere = try? await Self.transport().send(URLRequest(url: url))
        #expect(elsewhere?.1.statusCode != 200)
        #expect(StubProtocol.seen == [url])

        let good = URL(string: "https://ia800.us.archive.org/x.jpg")!
        StubProtocol.reset(.redirect(to: good))
        let followed = try await Self.transport().send(URLRequest(url: url))
        #expect(followed.1.statusCode == 200 && followed.1.url == good)
        #expect(StubProtocol.seen == [url, good])
    }
}

/// A local stand-in for the image hosts. Answers in-process; nothing leaves the machine.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    enum Mode {
        case stream(chunk: Int, total: Int)
        case declared(length: Int)
        case redirect(to: URL)
    }
    private struct State {
        var mode: Mode = .declared(length: 0)
        var seen: [URL] = []
        var sent = 0
    }
    private static let state = OSAllocatedUnfairLock(initialState: State())
    static func reset(_ mode: Mode) { state.withLock { $0 = State(mode: mode) } }
    static var seen: [URL] { state.withLock { $0.seen } }
    static var sentBytes: Int { state.withLock { $0.sent } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    private var stopped = OSAllocatedUnfairLock(initialState: false)

    override func startLoading() {
        guard let url = request.url else { return }
        let mode = Self.state.withLock { s in s.seen.append(url); return s.mode }
        let png = OutsideArtHardeningTests.image(width: 4, height: 4, type: .png)
        switch mode {
        case .redirect(let target) where url != target:
            let response = HTTPURLResponse(url: url, statusCode: 307, httpVersion: "HTTP/1.1",
                                           headerFields: ["Location": target.absoluteString])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
            client?.urlProtocolDidFinishLoading(self)
        case .redirect:
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "image/png"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: png)
            client?.urlProtocolDidFinishLoading(self)
        case .declared(let length):
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Length": String(length)])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: png)
            client?.urlProtocolDidFinishLoading(self)
        case .stream(let chunk, let total):
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            DispatchQueue.global().async { [self] in
                var sent = 0
                while sent < total, !stopped.withLock({ $0 }) {
                    client?.urlProtocol(self, didLoad: Data(count: chunk))
                    sent += chunk
                    let total = sent
                    Self.state.withLock { $0.sent = total }
                    Thread.sleep(forTimeInterval: 0.01)
                }
                if !stopped.withLock({ $0 }) { client?.urlProtocolDidFinishLoading(self) }
            }
        }
    }

    override func stopLoading() { stopped.withLock { $0 = true } }
}
