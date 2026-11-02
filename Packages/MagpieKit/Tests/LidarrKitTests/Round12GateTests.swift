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

    // MARK: M4

    static let keepMove = WriteGateTests.Call("PUT", "artist/editor",
        #"{"artistIds":[42],"rootFolderPath":"/music/library","moveFiles":true,"qualityProfileId":9,"tags":[2],"applyTags":"remove"}"#)

    /// The Keep move only goes when the main root has no folder of the find's name (loosely) and Lidarr's folder name
    /// is the find's current one, both read fresh at send time; an unreadable check refuses too.
    @Test(arguments: [
        (["Owner", "Find"], "Find", false), (["Owner", "find"], "Find", false), (["FÏND"], "Find", false),
        (["Owner"], "Find2", false), (["Owner"], nil, false), (["Owner"], "Find", true),
    ] as [([String], String?, Bool)])
    func keepMoveRefusedWhenTheDestinationIsTaken(_ folders: [String], _ named: String?, _ down: Bool) async throws {
        let fake = try await WriteConfinementTests.Fake(mainFolders: folders, lookupFolder: named, movePreflightDown: down)
        let gate = await fake.gate()
        do {
            _ = try await gate.send(Self.keepMove.method, Self.keepMove.path, body: WriteConfinementTests.body(Self.keepMove))
            Issue.record("sent the move with \(folders) / \(named ?? "nil") / down \(down)")
        } catch {}
        #expect(fake.writes.isEmpty)
    }

    @Test func keepMoveGoesWhenTheDestinationIsFree() async throws {
        let fake = try await WriteConfinementTests.Fake()
        let gate = await fake.gate()
        _ = try await gate.send(Self.keepMove.method, Self.keepMove.path, body: WriteConfinementTests.body(Self.keepMove))
        #expect(fake.writes.count == 1)
    }

    // MARK: Lows

    /// L3: a grab record without a download id doesn't prove Lidarr started this download.
    @Test func aGrabWithoutADownloadIdDoesNotCount() async throws {
        let t = MockTransport()
        t.stub(pathSuffix: "/history", body: json(#"{"records":[{"eventType":"grabbed"}]}"#))
        let (client, _) = makeClient(t)
        #expect(try await client.grabbed(downloadId: "abc") == false)
        let t2 = MockTransport()
        t2.stub(pathSuffix: "/history", body: json(#"{"records":[{"eventType":"grabbed","downloadId":"abc"}]}"#))
        #expect(try await makeClient(t2).0.grabbed(downloadId: "abc"))
    }

    /// L7: a present but undecodable `keepIntentAt` fails the entry (the ledger file is then kept aside and every check
    /// fails closed) instead of reading as "no Keep under way".
    @Test func aMalformedKeepIntentFailsClosed() throws {
        let entry = #"{"lidarrArtistId":42,"albumId":50,"rgMbid":"00000000-0000-0000-0000-000000000050","createdArtist":true,"wasMonitoredBefore":false,"root":"/m","mode":"finds","keepIntentAt":"soon"}"#
        #expect(throws: (any Error).self) { try JSONDecoder().decode(LedgerEntry.self, from: json(entry)) }
        let ok = #"{"lidarrArtistId":42,"albumId":50,"rgMbid":"00000000-0000-0000-0000-000000000050","createdArtist":true,"wasMonitoredBefore":false,"root":"/m","mode":"finds"}"#
        #expect(try JSONDecoder().decode(LedgerEntry.self, from: json(ok)).keepIntentAt == nil)
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
