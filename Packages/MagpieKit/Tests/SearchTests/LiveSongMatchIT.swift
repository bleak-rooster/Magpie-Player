import Foundation
import Testing
import ListenBrainzKit
import MagpieCore
@testable import Search
@testable import Requests

/// Round 19, live (`MAGPIE_LIVE=1` only: real MusicBrainz, a few minutes at its 1 request/s). Aurral's Trending is
/// Deezer's chart, so the test reads Deezer's public chart (test data only; the app never contacts Deezer) to stand in for
/// "a song found through Aurral": each is matched without the server's links (MusicBrainz's search alone, the Lidarr-only
/// case) and the release a Try would ask for is printed.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MAGPIE_LIVE"] == "1"), .serialized)
struct LiveSongMatchIT {
    let transport = URLSessionTransport(timeout: 20)

    struct ChartDTO: Decodable {
        struct Track: Decodable {
            struct Named: Decodable { var name: String?; var title: String? }
            var id: Int; var title: String; var duration: Int?; var artist: Named; var album: Named
        }
        var data: [Track]
    }

    func chart() async throws -> [OutsideSong] {
        var request = URLRequest(url: URL(string: "https://api.deezer.com/chart/0/tracks?limit=40")!)
        request.httpMethod = "GET"
        let (data, _) = try await transport.send(request)
        return try JSONDecoder().decode(ChartDTO.self, from: data).data.map {
            OutsideSong(title: $0.title, artist: $0.artist.name ?? "", album: $0.album.title,
                        duration: $0.duration.map(TimeInterval.init), previewId: String($0.id))
        }
    }

    @Test func chartSongsAreMatchedAndReleasesPicked() async throws {
        let mb = MusicBrainzClient(transport: transport, userAgent: MusicBrainzClient.userAgent(version: "live-test"))
        let finder = OutsideSongMatch.Finder(search: { try await mb.searchRecordings(title: $0, artist: $1) })
        let noLinks: OutsideSongMatch.Links = { _, _, _ in throw OutsideSongMatch.Failure.unmatched }
        let noRelease: OutsideSongMatch.Release = { _ in nil }
        var songs = try await chart()
        // Hard cases: a duet credited to both, a single never on an album, a hit on dozens of compilations.
        for (q, a) in [("Die With A Smile", "Lady Gaga"), ("APT.", "ROSÉ"), ("Good Luck, Babe!", "Chappell Roan"),
                       ("Not Like Us", "Kendrick Lamar"), ("Espresso", "Sabrina Carpenter")] {
            songs.append(OutsideSong(title: q, artist: a))
        }
        var matched = 0, lines: [String] = []
        for song in songs {
            guard let found = try? await OutsideSongMatch.resolve(song, links: noLinks, release: noRelease, finder: finder),
                  let id = found.recordingMBID else {
                lines.append("UNMATCHED  \(song.artist) – \(song.title) [\(song.album ?? "")]")
                continue
            }
            matched += 1
            let recording = try await mb.recording(id)
            var fits = Set(recording.releases.filter(RequestRunner.fitsFindsProfile).map(\.releaseGroup.id))
            var extras = ""
            if ReleasePicker.smallest(containing: recording, available: fits) == nil {
                fits = Set(recording.releases.filter(RequestRunner.fitsFindsExtras).map(\.releaseGroup.id))
                extras = " (Extras)"
            }
            let order = ReleasePicker.ordered(containing: recording, available: fits)
            let named = order.prefix(3).map { rg in
                recording.releases.first { $0.releaseGroup.id == rg }.map { "\($0.releaseGroup.primaryType ?? "?"):\($0.title)" } ?? "?"
            }
            lines.append("MATCHED \(song.artist) – \(song.title): \(recording.releases.count) releases → \(named.joined(separator: " > "))\(extras)")
        }
        let report = lines.joined(separator: "\n") + "\nmatched \(matched)/\(songs.count)"
        try report.write(toFile: NSTemporaryDirectory() + "live-song-match.txt", atomically: true, encoding: .utf8)
        print(report)
        #expect(matched * 10 >= songs.count * 9, "at least 90% matched")
    }
}
