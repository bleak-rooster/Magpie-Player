import Foundation
import Testing
@testable import MagpieCore

@Suite struct ModelsTests {
    @Test func mbidRejectsGarbage() {
        #expect(MBID("") == nil)
        #expect(MBID("not-a-uuid") == nil)
        #expect(MBID("5b11f4ce-a62d-471e-81fc-a69a8278c7d") == nil)
    }

    @Test func mbidLowercases() throws {
        let mbid = try #require(MBID("5B11F4CE-A62D-471E-81FC-A69A8278C7DA"))
        #expect(mbid.rawValue == "5b11f4ce-a62d-471e-81fc-a69a8278c7da")
        #expect(mbid == MBID("5b11f4ce-a62d-471e-81fc-a69a8278c7da"))
    }

    @Test func mbidCodableRoundTripAndRejectsBadJSON() throws {
        let mbid = try #require(MBID("5b11f4ce-a62d-471e-81fc-a69a8278c7da"))
        let data = try JSONEncoder().encode([mbid])
        #expect(String(decoding: data, as: UTF8.self) == "[\"5b11f4ce-a62d-471e-81fc-a69a8278c7da\"]")
        #expect(try JSONDecoder().decode([MBID].self, from: data) == [mbid])
        #expect(throws: DecodingError.self) { try JSONDecoder().decode([MBID].self, from: Data("[\"nope\"]".utf8)) }
    }

    @Test func qualityFromSuffix() {
        #expect(Quality.from(suffix: "flac", bitRate: nil) == .lossless)
        #expect(Quality.from(suffix: "FLAC", bitRate: 900) == .lossless)
        #expect(Quality.from(suffix: "alac", bitRate: nil) == .lossless)
        #expect(Quality.from(suffix: "wav", bitRate: nil) == .lossless)
        #expect(Quality.from(suffix: "mp3", bitRate: 320) == .standard)
        #expect(Quality.from(suffix: "aac", bitRate: nil) == .standard)
        #expect(Quality.from(suffix: "opus", bitRate: nil) == .standard)
        #expect(Quality.from(suffix: nil, bitRate: nil) == .standard)
    }

    @Test func songCodableRoundTrip() throws {
        let song = Song(id: "s1", title: "T", artist: "A", album: "Al", duration: 200,
                        recordingMBID: MBID("5b11f4ce-a62d-471e-81fc-a69a8278c7da"), isrcs: ["X"])
        let back = try JSONDecoder().decode(Song.self, from: JSONEncoder().encode(song))
        #expect(back == song)
        #expect(back.starred == false)
    }

    @Test func albumListTypeRawValues() {
        #expect(AlbumListType.alphabeticalByName.rawValue == "alphabeticalByName")
        #expect(AlbumListType.random.rawValue == "random")
    }
}
