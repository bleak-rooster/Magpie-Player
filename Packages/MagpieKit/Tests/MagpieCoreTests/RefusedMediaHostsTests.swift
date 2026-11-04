import Foundation
import MagpieCore
import MagpieTestSupport
import Testing

/// Round 14 A7 fix round 1 (controller ruling on the owner's rule, plan decision 11): the phone never loads anything
/// from Deezer or Apple, whatever named it. Outside art (a Lidarr artist picture, a Cover Art Archive redirect) on
/// their hosts is refused: the placeholder.
@MainActor @Suite struct RefusedMediaHostsTests {
    static let refused = [
        "https://e-cdns-images.dzcdn.net/images/artist/1/500x500.jpg", "https://dzcdn.net/a.jpg",
        "https://cdns-images.DZCDN.NET/a.jpg", "https://api.deezer.com/artist/1/image", "https://deezer.com/a.jpg",
        "https://www.deezer.com./a.jpg", "https://is1-ssl.mzstatic.com/image/thumb/a/600x600bb.jpg",
        "https://mzstatic.com/a.jpg", "https://music.apple.com/a.jpg", "https://itunes.apple.com/a.jpg",
        "https://apple.com/a.jpg",
    ]

    @Test func theListIsDeezerAndApple() {
        #expect(RefusedMediaHosts.domains == ["deezer.com", "dzcdn.net", "mzstatic.com", "apple.com"])
        for s in Self.refused { #expect(RefusedMediaHosts.refuses(URL(string: s)!), "\(s)") }
        for s in ["https://notdeezer.com/a.jpg", "https://dzcdn.net.example.org/a.jpg", "https://images.lidarr.audio/a.jpg",
                  "https://coverartarchive.org/release/x", "https://pineapple.com/a.jpg", "https://applecom.example/a.jpg"] {
            #expect(!RefusedMediaHosts.refuses(URL(string: s)!), "\(s)")
        }
    }

    @Test func outsideArtRefusesThemFirstAndOnRedirect() {
        let artist = OutsideArtKey.artist(OutsideArtTests.artist)
        for s in Self.refused { #expect(!OutsideArtPolicy.isAllowed(URL(string: s)!, for: artist), "\(s)") }
        let caa = URL(string: "https://coverartarchive.org/release-group/x/front-250")!
        #expect(!OutsideArtPolicy.allowsRedirect(from: caa, to: URL(string: "https://e-cdns-images.dzcdn.net/a.jpg")!))
        let lidarr = URL(string: "https://is1-ssl.mzstatic.com/a.jpg")!
        #expect(!OutsideArtPolicy.allowsRedirect(from: lidarr, to: URL(string: "https://is2-ssl.mzstatic.com/b.jpg")!),
                "not even within the same Apple host family")
    }

    /// A Lidarr answer naming a Deezer or Apple picture shows the placeholder, and nothing is asked of them.
    @Test func aLidarrArtistPictureOnTheirHostsIsThePlaceholder() async {
        for s in Self.refused {
            let t = MockTransport()
            t.stub(pathSuffix: ".jpg", body: OutsideArtTests.png())
            let l = OutsideArtLoader(transport: t, userAgent: OutsideArtTests.ua, artistImage: { _ in URL(string: s) },
                                     isOffline: { false })
            #expect(await l.image(.artist(OutsideArtTests.artist)) == nil, "\(s)")
            #expect(t.requests.isEmpty, "\(s)")
        }
    }
}
