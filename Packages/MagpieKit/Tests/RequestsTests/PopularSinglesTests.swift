import Foundation
import os
import Testing
import LidarrKit
import MagpieCore
@testable import Requests

/// Round 19 (owner, 2026-11-05: popular singles weren't found): a new artist whose song is only on a soundtrack or a remix
/// release is added with "Magpie Finds Extras" (made once through the gate), so Lidarr lists that release; a song on a
/// studio release changes nothing.
@Suite struct PopularSinglesTests {
    /// Lidarr's metadata profiles for these tests: none at first; a POST makes one (id 31).
    static func serveMetadataProfiles(_ h: Harness) {
        let made = OSAllocatedUnfairLock(initialState: [Data]())
        h.server.transport.stub(pathSuffix: "/api/v1/metadataprofile/schema") { _ in
            func list(_ key: String, _ names: [String]) -> [[String: Any]] {
                names.enumerated().map { [key: ["id": $0.offset, "name": $0.element], "allowed": false] }
            }
            return FakeLidarr.reply(["id": 0, "name": "", "primaryAlbumTypes": list("albumType", ["Album", "EP", "Single", "Other"]),
                                     "secondaryAlbumTypes": list("albumType", ["Studio", "Compilation", "Soundtrack", "Live", "Remix"]),
                                     "releaseStatuses": list("releaseStatus", ["Official", "Promotion", "Bootleg"])])
        }
        h.server.transport.stub(method: "POST", pathSuffix: "/api/v1/metadataprofile") { req in
            var body = (try? JSONSerialization.jsonObject(with: req.httpBody ?? Data())) as? [String: Any] ?? [:]
            body["id"] = 31
            let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
            made.withLock { $0.append(data) }
            return FakeLidarr.reply(body, status: 201)
        }
        h.server.transport.stub(pathSuffix: "/api/v1/metadataprofile") { _ in
            FakeLidarr.reply(made.withLock { $0 }.compactMap { try? JSONSerialization.jsonObject(with: $0) })
        }
    }

    static func artistPosts(_ h: Harness) -> [[String: Any]] {
        h.server.writeBodies().filter { $0.0 == "POST artist" }.map(\.1)
    }

    @Test func aSoundtrackOnlySongAddsTheArtistWithExtras() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        Self.serveMetadataProfiles(h)
        h.server.artistIsNew()
        let id = try await h.runner.tryRecording(h.recording(recSoundtrackOnly), tier: .standard)
        await h.runner.settle()
        let r = try #require(await h.request(id))
        #expect(r.findsExtras == true && r.plan?.releaseGroupMBID == rgSoundtrack, "\(r.state)")
        let made = h.server.writeBodies().filter { $0.0 == "POST metadataprofile" }.map(\.1)
        #expect(made.count == 1 && made.first?["name"] as? String == "Magpie Finds Extras")
        let secondary = (made.first?["secondaryAlbumTypes"] as? [[String: Any]] ?? []).filter { $0["allowed"] as? Bool == true }
            .compactMap { ($0["albumType"] as? [String: Any])?["name"] as? String }
        #expect(Set(secondary) == ["Studio", "Soundtrack", "Remix"])
        let log = await h.gate.changeLog().map { "\($0.method) \($0.path)" }
        let state = await h.request(id)?.state
        let add = try #require(Self.artistPosts(h).first, "\(log) \(String(describing: state)) \(String(describing: r.note))")
        #expect(add["metadataProfileId"] as? Int == 31, "the Extras profile, not Magpie Finds")
        #expect((add["addOptions"] as? [String: Any])?["albumsToMonitor"] as? [String] == [rgSoundtrack.rawValue])
    }

    @Test func aStudioSongChangesNothing() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        h.server.artistIsNew()
        let id = try await h.runner.tryRecording(h.recording(recSingleAndAlbum), tier: .standard)
        await h.runner.settle()
        #expect(await h.request(id)?.findsExtras == nil)
        #expect(!h.server.writeBodies().contains { $0.0 == "POST metadataprofile" })
        #expect(Self.artistPosts(h).first?["metadataProfileId"] as? Int == Harness.findsSetup.metadataProfileId)
    }

    /// Lidarr's metadata for `album/lookup?term=lidarr:<rg>`: each listed release group with the artist it's filed under.
    static func serveAlbumLookup(_ h: Harness, _ listed: [MBID: MBID]) {
        h.server.transport.stub(pathSuffix: "/api/v1/album/lookup") { req in
            let term = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "term" }?.value ?? ""
            let rg = MBID(String(term.dropFirst("lidarr:".count)))
            guard let rg, let artist = listed[rg] else { return FakeLidarr.reply([[String: Any]]()) }
            return FakeLidarr.reply([["foreignAlbumId": rg.rawValue, "title": "x", "artist": ["foreignArtistId": artist.rawValue]]])
        }
    }

    /// A release Lidarr's metadata doesn't know is never asked for: the next one is (here the album, not the single).
    @Test func aReleaseLidarrDoesntKnowIsSkipped() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        Self.serveAlbumLookup(h, [rgAlbum: artistA])
        h.server.artistIsNew()
        let id = try await h.runner.tryRecording(h.recording(recSingleAndAlbum), tier: .standard)
        await h.runner.settle()
        #expect(await h.request(id)?.plan?.releaseGroupMBID == rgAlbum)
        #expect(await h.request(id)?.releaseAlternates?.contains(rgSingle) != true, "never waited for later either")
    }

    /// The release is filed under another artist (a soundtrack's cast): that artist is the one added. "Various Artists"
    /// never is.
    @Test func theArtistLidarrFilesItUnderIsAdded() async throws {
        let cast = mbid(77)
        for (owner, expected) in [(cast, cast), (RequestRunner.variousArtists, artistA)] {
            let h = await Harness(setup: Harness.findsSetup)
            Self.serveAlbumLookup(h, [rgSingle: owner, rgAlbum: artistA])
            h.server.artistIsNew()
            let id = try await h.runner.tryRecording(h.recording(recSingleAndAlbum), tier: .standard)
            await h.runner.settle()
            let plan = await h.request(id)?.plan
            #expect(plan?.artistMBID == expected, "owner \(owner)")
            #expect(plan?.releaseGroupMBID == (owner == cast ? rgSingle : rgAlbum), "owner \(owner)")
        }
    }
}

