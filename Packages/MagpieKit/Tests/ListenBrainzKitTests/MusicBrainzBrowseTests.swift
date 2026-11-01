import Foundation
import Testing
import MagpieCore
import MagpieTestSupport
@testable import ListenBrainzKit

private let artist = MBID("11111111-1111-1111-1111-111111111111")!
private let rg1 = MBID("22222222-2222-2222-2222-222222222221")!
private let rg2 = MBID("22222222-2222-2222-2222-222222222222")!
private let rel1 = MBID("33333333-3333-3333-3333-333333333331")!
private let rel2 = MBID("33333333-3333-3333-3333-333333333332")!
private let rec1 = MBID("44444444-4444-4444-4444-444444444441")!
private let rec2 = MBID("44444444-4444-4444-4444-444444444442")!

/// R19: the outside artist and album pages browse MusicBrainz (official releases only, the app UA, 1 request/s).
@Suite struct MusicBrainzBrowseTests {
    private func client(_ t: MockTransport) -> MusicBrainzClient {
        MusicBrainzClient(transport: t, userAgent: MusicBrainzClient.userAgent(version: "9.9.9"), limiter: FakeClock().limiter())
    }

    @Test func artistReleaseGroupsAreOfficialAndUnique() async throws {
        let t = MockTransport()
        t.stub(pathSuffix: "/ws/2/release", body: json("""
        {"release-count": 3, "releases": [
          {"id": "\(rel1.rawValue)", "title": "Continuum", "status": "Official", "date": "2019-03-15",
           "release-group": {"id": "\(rg1.rawValue)", "title": "Continuum", "primary-type": "Album",
                             "secondary-types": [], "first-release-date": "2019-03-15"}},
          {"id": "\(rel2.rawValue)", "title": "Continuum (Deluxe)", "status": "Official", "date": "2020",
           "release-group": {"id": "\(rg1.rawValue)", "title": "Continuum", "primary-type": "Album",
                             "secondary-types": [], "first-release-date": "2019-03-15"}},
          {"id": "\(rel2.rawValue)", "title": "Live", "status": "Official",
           "release-group": {"id": "\(rg2.rawValue)", "title": "Live at Home", "primary-type": "Album",
                             "secondary-types": ["Live"], "first-release-date": "2021"}},
          {"id": "nope", "title": "Broken"}
        ]}
        """))
        let groups = try await client(t).officialReleaseGroups(artist: artist)
        #expect(groups.map(\.id) == [rg1, rg2])
        #expect(groups[0] == MBReleaseGroupSummary(id: rg1, title: "Continuum", primaryType: "Album", secondaryTypes: [],
                                                   firstReleaseDate: "2019-03-15"))
        #expect(groups[1].secondaryTypes == ["Live"])
        let req = try #require(t.requests.first)
        #expect(req.url?.host == "musicbrainz.org")
        #expect(req.value(forHTTPHeaderField: "User-Agent") == "Magpie/9.9.9 ( https://github.com/bleak-rooster )")
        let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: req.url!, resolvingAgainstBaseURL: false)?
            .queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(query["artist"] == artist.rawValue)
        #expect(query["status"] == "official")
        #expect(query["type"] == "album|ep|single")
        #expect(query["inc"] == "release-groups")
        #expect(t.requests.count == 1, "every release fit on the first page")
    }

    @Test func releasesOfAGroupCarryTheirTracks() async throws {
        let t = MockTransport()
        t.stub(pathSuffix: "/ws/2/release", body: json("""
        {"release-count": 1, "releases": [
          {"id": "\(rel1.rawValue)", "title": "Continuum", "status": "Official", "date": "2019-03-15",
           "media": [{"position": 1, "tracks": [
              {"position": 2, "title": "Drift", "length": 11000, "recording": {"id": "\(rec2.rawValue)", "title": "Drift"}},
              {"position": 1, "title": "First Light", "length": 14000, "recording": {"id": "\(rec1.rawValue)", "title": "First Light"}},
              {"position": 3, "title": "No id", "recording": {}}
           ]}]}
        ]}
        """))
        let releases = try await client(t).officialReleases(releaseGroup: rg1)
        let release = try #require(releases.first)
        #expect(release.id == rel1 && release.status == "Official" && release.date == "2019-03-15")
        #expect(release.tracks.map(\.title) == ["First Light", "Drift"])
        #expect(release.tracks.map(\.recording) == [rec1, rec2])
        #expect(release.tracks.first?.length == 14)
        let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: t.requests[0].url!, resolvingAgainstBaseURL: false)?
            .queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(query["release-group"] == rg1.rawValue)
        #expect(query["status"] == "official")
        #expect(query["inc"] == "recordings")
    }

    @Test func browseErrorsAreTyped() async throws {
        let t = MockTransport()
        t.stub(pathSuffix: "/ws/2/release", status: 503)
        await #expect(throws: MusicBrainzError.http(status: 503)) { try await client(t).officialReleaseGroups(artist: artist) }
    }
}
