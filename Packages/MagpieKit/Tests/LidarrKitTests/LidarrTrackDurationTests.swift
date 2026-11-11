import Foundation
import MagpieCore
import MagpieTestSupport
import Testing
@testable import LidarrKit

/// Round 26 K1 (owner, 2026-11-10): the album step compares a track's length with the top song's (D260), so a Lidarr
/// track carries its `duration`: seconds from Lidarr's milliseconds, nil when missing or unusable, never a trap. A bad
/// length never drops the track.
@Suite struct LidarrTrackDurationTests {
    private func track(_ duration: String) throws -> LidarrTrack {
        try JSONDecoder().decode(LidarrTrack.self, from: json(#"{"id":7,"albumId":3,"trackFileId":11,"title":"Song","#
            + #""foreignRecordingId":"rec-1","duration":\#(duration)}"#))
    }

    @Test func track_durationFromMilliseconds() throws {
        #expect(try track("245000").duration == 245)
        #expect(try track("211500.0").duration == 211.5)
        #expect(try track("1").duration == 0.001)
        #expect(try track("86400000").duration == 86_400, "24 h is the cap, inclusive")
        let full = try track("245000")
        #expect(full.id == 7 && full.albumId == 3 && full.hasFile && full.title == "Song" && full.foreignRecordingId == "rec-1")
    }

    @Test func track_badDurationIsNil() throws {
        for bad in ["0", "-5000", "86400001", "1e300", "\"245000\"", "null", "true", "{}", "[]"] {
            let t = try track(bad)
            #expect(t.duration == nil, "\(bad)")
            #expect(t.id == 7 && t.hasFile && t.title == "Song", "the track itself still decodes: \(bad)")
        }
        let missing = try JSONDecoder().decode(LidarrTrack.self, from: json(#"{"id":8}"#))
        #expect(missing.duration == nil && missing.id == 8 && !missing.hasFile)
    }

    @Test func track_artistTracksReadCarriesDurations() async throws {
        let (client, transport) = makeClient()
        transport.stub(pathSuffix: "/track", body: json(#"[{"id":1,"albumId":2,"trackFileId":3,"duration":200000},"#
            + #"{"id":2,"albumId":2,"duration":"x"},{"id":"bad"}]"#))
        let tracks = try await client.tracks(artistId: 9)
        #expect(tracks.map(\.id) == [1, 2])
        #expect(tracks.map(\.duration) == [200, nil])
    }

    @Test func track_memberwiseInitKeepsDurationOptional() {
        let t = LidarrTrack(id: 1, albumId: 2, trackFileId: 3, foreignTrackId: nil, foreignRecordingId: nil)
        #expect(t.duration == nil)
        let timed = LidarrTrack(id: 1, albumId: 2, trackFileId: 3, foreignTrackId: nil, foreignRecordingId: nil, duration: 90)
        #expect(timed.duration == 90)
    }
}
