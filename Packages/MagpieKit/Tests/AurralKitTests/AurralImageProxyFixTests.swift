import Foundation
import MagpieCore
import MagpieTestSupport
import Testing
@testable import AurralKit

/// Round 14 A7 fix round 1, minors.
@Suite struct AurralImageProxyFixTests {
    /// M1: a call cancelled before it starts sends nothing (the transport's cancel used to come before its task).
    @Test func aCancelledCallSendsNothing() async throws {
        let request = URLRequest(url: URL(string: "http://127.0.0.1:9/api/image-proxy/x")!)
        let outcome = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do { _ = try await AurralOpenTransport().send(request); return "sent" }
            catch is CancellationError { return "cancelled" }
            catch { return "error: \(error)" }
        }.value
        #expect(outcome == "cancelled")
    }

    /// M2: one server is one key, however its address is spelt.
    @Test func oneServerOneKey() async throws {
        let a = URL(string: "HTTP://Aurral.Home:3001/")!, b = URL(string: "http://aurral.home:3001")!
        #expect(AurralImageProxy.serverKey(a) == AurralImageProxy.serverKey(b))
        #expect(AurralImageProxy.serverKey(a) != AurralImageProxy.serverKey(URL(string: "http://aurral.home:3002")!))

        let stub = StubAurral()
        stub.useAurral213()
        let client = AurralClient(base: stub.base, session: stub.signedInSession(), transport: stub)
        _ = try await client.trending()
        var parts = URLComponents(url: stub.base, resolvingAgainstBaseURL: false)!
        parts.host = parts.host?.uppercased()
        let proxy = AurralImageProxy(base: parts.url!, directory: nil, openTransport: stub)
        let art = AurralImage("https://cdn-images.dzcdn.net/images/cover/3135556/250x250-000000-80-0-0.jpg")!
        #expect(await proxy.imageData(for: art, client: client) != nil, "the same server, spelt differently")
    }

    /// M3: the known links are bounded by forgetting the least recently named, never by refusing new pictures.
    @Test func knownLinksForgetTheOldestNotTheNewest() async {
        let session = AurralSession(username: "u", password: nil, login: nil)
        await session.noteImageSources(["a", "b", "c"], limit: 3)
        await session.noteImageSources(["a"], limit: 3)   // named again: the most recent
        await session.noteImageSources(["d"], limit: 3)
        #expect(await session.knowsImageSource("d"), "a new picture is learnt")
        #expect(await session.knowsImageSource("a"))
        #expect(await session.knowsImageSource("c"))
        #expect(await !session.knowsImageSource("b"), "the least recently named is forgotten")
    }
}
