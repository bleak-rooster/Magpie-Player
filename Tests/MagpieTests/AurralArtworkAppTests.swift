import AurralKit
import Foundation
import MagpieCore
import MagpieTestSupport
import Testing
import UIKit
@testable import Magpie

/// Round 14 A7 (D111, D112, plan decision 11): every picture Aurral names (Trending, Recommended, the Discover
/// playlists, Home's Aurral tiles) is shown through Aurral's image proxy; the phone never asks Deezer or Apple.
extension DiscoverAppTests {
    private var outsideAsks: [URLRequest] {
        transport.navidrome.requests.filter { request in
            let host = request.url?.host()?.lowercased() ?? ""
            return host.contains("dzcdn") || host.contains("deezer") || host.contains("mzstatic") || host.contains("apple")
        }
    }

    @Test func aurralPicturesGoThroughItsImageProxy() async throws {
        let (model, _) = try await previewModel()
        defer { model.signOut() }
        let client = try #require(model.aurralClient)
        let art = try #require(try await client.trending().songs?.items.first?.artwork)
        #expect(art.raw.contains("dzcdn"), "the fixture names Deezer's CDN")

        let picture = await model.aurralArtwork(art, side: 47)
        #expect(picture != nil)
        #expect(aurral.imageProxySources == [art.raw])
        let get = try #require(aurral.requests.last { $0.url?.path.hasPrefix("/api/image-proxy/") == true })
        #expect(get.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(outsideAsks.isEmpty, "nothing asked of Deezer or Apple")

        // Shown again: from memory, nothing more asked.
        let asked = aurral.requests.count
        #expect(await model.aurralArtwork(art, side: 47) != nil)
        #expect(aurral.requests.count == asked)
    }

    @Test func aPictureAurralNeverNamedIsNeverSent() async throws {
        let (model, _) = try await previewModel()
        defer { model.signOut() }
        let stranger = try #require(AurralImage("https://e-cdns-images.dzcdn.net/images/cover/424242/1.jpg"))
        #expect(await model.aurralArtwork(stranger, side: 48) == nil)
        #expect(aurral.imageProxySources.isEmpty && outsideAsks.isEmpty)
    }

    /// Fix round 1 M2: one image proxy (one bound of four) per server, however its address is spelt.
    @Test func oneImageProxyPerServer() {
        let directory = tmp
        let a = AurralImageProxies.proxy(for: URL(string: "http://Aurral.Home:3001/")!, dataDirectory: directory, transport: transport)
        let b = AurralImageProxies.proxy(for: URL(string: "http://aurral.home:3001")!, dataDirectory: directory, transport: transport)
        let c = AurralImageProxies.proxy(for: URL(string: "http://aurral.home:3001")!, dataDirectory: directory, transport: transport)
        #expect(a === b && b === c)
        let other = AurralImageProxies.proxy(for: URL(string: "http://aurral.home:3002")!, dataDirectory: directory, transport: transport)
        #expect(other !== a)
    }

    /// No Aurral, offline, or Aurral failing: the placeholder, and nothing asked of anyone else.
    @Test func withoutAurralOrOfflineThePlaceholder() async throws {
        let art = try #require(AurralImage("https://cdn-images.dzcdn.net/images/cover/3135557/250x250-000000-80-0-0.jpg"))
        let (bare, _) = try await previewModel(aurralSetUp: false)
        #expect(await bare.aurralArtwork(art, side: 46) == nil)
        bare.signOut()

        let (model, _) = try await previewModel()
        defer { model.signOut() }
        _ = try await model.aurralClient?.trending()
        model.updatePreferences { $0.downloads.offlineMode = .on }
        #expect(await model.aurralArtwork(art, side: 46) == nil)
        model.updatePreferences { $0.downloads.offlineMode = .automatic }
        aurral.setImageProxyRefused(art.raw)
        #expect(await model.aurralArtwork(art, side: 46) == nil)
        #expect(outsideAsks.isEmpty)
    }
}
