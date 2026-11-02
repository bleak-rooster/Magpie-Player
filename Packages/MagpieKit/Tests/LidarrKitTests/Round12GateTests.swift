import Foundation
import Testing
import MagpieCore
import MagpieTestSupport
@testable import LidarrKit

/// Round 12 security review: M2 (ArtistSearch confined, RefreshAlbum gone) and M3 (exact command bodies).
@Suite struct Round12GateTests {
    typealias Fake = KeptLossyDeleteTests.Fake

    static func refused(_ gate: LidarrWriteGate, _ body: String) async -> Bool {
        await KeptLossyDeleteTests.refused(gate, "POST", "command", body)
    }

    // MARK: M2

    /// ArtistSearch only for an artist the ledger says Magpie created, with the same MBID read fresh.
    @Test func artistSearchOnlyForAnArtistMagpieCreated() async throws {
        let fake = try await Fake()
        let gate = await fake.gate()
        #expect(await Self.refused(gate, #"{"name":"ArtistSearch","artistId":99}"#), "unknown artist")
        #expect(await Self.refused(gate, #"{"name":"ArtistSearch","artistId":7}"#), "the owner's artist, in the ledger")
        #expect(fake.writes.isEmpty)
        _ = try await gate.send("POST", "command",
                                body: try JSONDecoder().decode(JSONValue.self, from: json(#"{"name":"ArtistSearch","artistId":42}"#)))
        #expect(fake.writes.count == 1)
    }

    @Test func artistSearchNeedsTheLedger() async throws {
        let fake = try await Fake()
        let plain = LidarrWriteGate(client: fake.client, logURL: fake.env.logURL, defaultsSuite: fake.env.defaults)
        await plain.setEnabled(true)
        #expect(await Self.refused(plain, #"{"name":"ArtistSearch","artistId":42}"#))
        #expect(fake.writes.isEmpty)
    }

    /// Nothing in the product sends RefreshAlbum: it is no longer allowed.
    @Test func refreshAlbumIsRefused() async throws {
        let fake = try await Fake()
        let gate = await fake.gate()
        #expect(await Self.refused(gate, #"{"name":"RefreshAlbum","albumId":50}"#))
        #expect(await Self.refused(gate, #"{"name":"RefreshAlbum","albumIds":[50]}"#))
        #expect(fake.writes.isEmpty)
    }

    // MARK: M3

    static let malformed: [String] = [
        // Extra keys.
        #"{"name":"AlbumSearch","albumIds":[50],"artistId":42}"#,
        #"{"name":"AlbumSearch","albumIds":[50],"x":1}"#,
        #"{"name":"RefreshArtist","artistId":42,"artistIds":[7]}"#,
        #"{"name":"RefreshArtist","artistId":42,"isNewArtist":true}"#,
        #"{"name":"ArtistSearch","artistId":42,"artistIds":[7]}"#,
        // Ids that aren't positive integers.
        #"{"name":"AlbumSearch","albumIds":[50,"99"]}"#,
        #"{"name":"AlbumSearch","albumIds":[50,0]}"#,
        #"{"name":"AlbumSearch","albumIds":[50,-1]}"#,
        #"{"name":"AlbumSearch","albumIds":[50.5]}"#,
        #"{"name":"AlbumSearch","albumIds":[true]}"#,
        #"{"name":"AlbumSearch","albumIds":50}"#,
        #"{"name":"RefreshArtist","artistId":"42"}"#,
        #"{"name":"RefreshArtist","artistId":42.5}"#,
        #"{"name":"ArtistSearch","artistId":"42"}"#,
        // Missing ids.
        #"{"name":"RefreshArtist"}"#,
        #"{"name":"RefreshArtist","artistIds":[42]}"#,
        #"{"name":"ArtistSearch"}"#,
        #"{"name":"AlbumSearch"}"#,
    ]

    @Test(arguments: malformed)
    func commandBodiesAreExact(_ body: String) async throws {
        let fake = try await Fake()
        let gate = await fake.gate()
        #expect(await Self.refused(gate, body), "sent: \(body)")
        #expect(fake.writes.isEmpty)
    }

    /// The exact shapes still go (the ledger knows album 50 and created artist 42).
    @Test func exactBodiesAreSent() async throws {
        let fake = try await Fake()
        let gate = await fake.gate()
        for text in [#"{"name":"AlbumSearch","albumIds":[50]}"#, #"{"name":"RefreshArtist","artistId":42}"#,
                     #"{"name":"ArtistSearch","artistId":42}"#] {
            _ = try await gate.send("POST", "command", body: try JSONDecoder().decode(JSONValue.self, from: json(text)))
        }
        #expect(fake.writes.count == 3)
    }
}
