import AurralKit
import Foundation
import MagpieCore
import MagpieTestSupport
import Testing
import UIKit
@testable import Magpie

/// B1 fix round (review 1, D125): an album cover no other source has comes from Aurral's catalog search (an allowed
/// route), matched by the album's MBID, through Aurral's image proxy. Never Deezer or Apple directly; nothing without
/// Aurral. Stubs only.
extension DiscoverAppTests {
    static let searchedAlbum = MBID("00000000-0000-4000-8000-000000000000")!

    @Test func aurralsCatalogCoverFillsAnAlbumNothingElseHas() async throws {
        let (model, _) = try await previewModel()
        defer { model.signOut() }
        let link = "https://images.example.org/covers/wide-open.jpg"
        aurral.setAlbumSearchCover(link)
        let none = MockTransport()   // every Cover Art Archive answer 404s; no Lidarr
        AppModel.outsideArtTransportForTesting = none
        defer { AppModel.outsideArtTransportForTesting = nil }
        let loader = model.makeOutsideArt()
        loader.note(Self.searchedAlbum, OutsideAlbumHint(title: "Wide Open", artist: "Stub Arrows"))
        #expect(await loader.image(.releaseGroup(Self.searchedAlbum)) != nil, "Aurral's cover, last before the placeholder")
        #expect(aurral.imageProxySources == [link], "through Aurral's image proxy only")
        let search = try #require(aurral.requests.last { $0.url?.path == "/api/search" })
        #expect(URLComponents(url: search.url!, resolvingAgainstBaseURL: false)?.queryItems?
            .contains(URLQueryItem(name: "scope", value: "album")) == true)
        #expect(!none.requests.contains { ($0.url?.host() ?? "").contains("example.org") }, "the link itself is never fetched")
    }

    /// Matched by MBID, never by name alone; and nothing at all without Aurral.
    @Test func aurralsCoverOnlyForTheSameAlbum() async throws {
        let (model, _) = try await previewModel()
        defer { model.signOut() }
        aurral.setAlbumSearchCover("https://images.example.org/covers/other.jpg")
        let other = MBID("11111111-0000-4000-8000-000000000000")!
        #expect(try await model.aurralAlbumCover(other, OutsideAlbumHint(title: "Wide Open", artist: "Stub Arrows")) == nil)
        #expect(aurral.imageProxySources.isEmpty)

        let (bare, _) = try await previewModel(aurralSetUp: false)
        defer { bare.signOut() }
        #expect(try await bare.aurralAlbumCover(Self.searchedAlbum, OutsideAlbumHint(title: "W", artist: "S")) == nil)
    }
}
