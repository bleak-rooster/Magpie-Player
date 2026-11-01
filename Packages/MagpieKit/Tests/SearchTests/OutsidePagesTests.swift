import Foundation
import Testing
import ListenBrainzKit
import MagpieCore
@testable import Search

private func id(_ n: Int) -> MBID { MBID(String(format: "00000000-0000-0000-0000-%012d", n))! }

private func group(_ n: Int, _ type: String?, _ secondary: [String] = [], _ date: String? = nil) -> MBReleaseGroupSummary {
    MBReleaseGroupSummary(id: id(n), title: "G\(n)", primaryType: type, secondaryTypes: secondary, firstReleaseDate: date)
}

/// R19: the outside artist page's sections and the outside album page's release.
@Suite struct OutsidePagesTests {
    @Test func artistSectionsStudioFirstOthersUnderMoreNewestFirst() {
        let sections = OutsideArtistSections.make([
            group(1, "Album", [], "2016"),
            group(2, "Album", [], "2019-03-15"),
            group(3, "Album", ["Live"], "2021"),
            group(4, "EP", [], "2018-05"),
            group(5, "Single", [], "2020-01-01"),
            group(6, "Single", [], nil),
            group(7, "Single", [], "2022"),
            group(8, "Album", ["Compilation"], "2015"),
            group(9, "Album", ["Soundtrack"], "2023"),
            group(10, "Broadcast", [], "2024"),
            group(11, nil, [], "2024"),
        ])
        #expect(sections.albums.map(\.id) == [id(2), id(1)])
        #expect(sections.eps.map(\.id) == [id(4)])
        #expect(sections.singles.map(\.id) == [id(7), id(5), id(6)], "undated last")
        #expect(sections.more.map(\.id) == [id(9), id(3), id(8)])
        #expect(sections.more.map(\.kind) == ["Soundtrack", "Live", "Compilation"])
        #expect(sections.albums.first?.year == 2019)
        #expect(!sections.isEmpty)
        #expect(OutsideArtistSections.make([group(10, "Broadcast")]).isEmpty)
    }

    @Test func albumTracklistPicksTheOfficialEarliestRelease() {
        func release(_ n: Int, _ status: String?, _ date: String?, tracks: Int) -> MBReleaseDetail {
            MBReleaseDetail(id: id(100 + n), title: "R\(n)", date: date, status: status,
                            tracks: (0..<tracks).map { MBTrack(recording: id(200 + $0), title: "T\($0)", length: 60) })
        }
        let promo = release(1, "Promotion", "2018", tracks: 3)
        let deluxe = release(2, "Official", "2020", tracks: 14)
        let original = release(3, "Official", "2019-03-15", tracks: 10)
        let undated = release(4, "Official", nil, tracks: 10)
        let empty = release(5, "Official", "2017", tracks: 0)
        #expect(OutsideReleasePick.pick([promo, deluxe, undated, original, empty]) == original)
        #expect(OutsideReleasePick.pick([undated, promo]) == undated, "official first, undated after dated")
        #expect(OutsideReleasePick.pick([promo]) == promo, "no official one: the earliest there is")
        #expect(OutsideReleasePick.pick([empty]) == nil, "nothing to list")
        #expect(OutsideReleasePick.pick([]) == nil)
    }

    @Test func catalogCachesPerSessionAndRetriesFailures() async throws {
        let calls = Counter()
        let catalog = OutsideCatalog(
            releaseGroups: { _ in
                if await calls.bump() == 1 { throw MusicBrainzError.http(status: 503) }
                return [group(1, "Album", [], "2019")]
            },
            releases: { _ in await calls.bump(); return [] })
        await #expect(throws: MusicBrainzError.self) { try await catalog.releaseGroups(artist: id(1)) }
        let first = try await catalog.releaseGroups(artist: id(1))
        let again = try await catalog.releaseGroups(artist: id(1))
        #expect(first == again && first.count == 1)
        #expect(await calls.value == 2, "a failure isn't kept; a success is")
        _ = try await catalog.release(releaseGroup: id(5))
        _ = try await catalog.release(releaseGroup: id(5))
        #expect(await calls.value == 3)
        await catalog.reset()
        _ = try await catalog.release(releaseGroup: id(5))
        #expect(await calls.value == 4)
    }

    @Test func tracksBecomeRecordingsForTry() {
        let release = MBReleaseDetail(id: id(100), title: "Continuum", date: "2019", status: "Official",
                                      tracks: [MBTrack(recording: id(200), title: "First Light", length: 14)])
        let recordings = OutsideReleasePick.recordings(release, artist: "Aurora Field", artistMBID: id(1))
        #expect(recordings == [ExternalRecording(recordingMBID: id(200), artistMBID: id(1), title: "First Light",
                                                 artist: "Aurora Field", releaseTitle: "Continuum", duration: 14,
                                                 source: .lidarr, releaseMBID: id(100))])
    }
}

private actor Counter {
    var value = 0
    @discardableResult func bump() -> Int { value += 1; return value }
}
