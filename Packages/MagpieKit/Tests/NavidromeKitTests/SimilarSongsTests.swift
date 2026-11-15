import Foundation
import Testing
import MagpieCore
import MagpieTestSupport
@testable import NavidromeKit

private func ok(_ body: String) -> Data {
    Data(#"{"subsonic-response":{"status":"ok","version":"1.16.1",\#(body)}}"#.utf8)
}

/// Round 27 P (owner, 2026-11-14): `getSimilarSongs2` for Automix (D282): library songs only, mapped like every song.
@Suite struct SimilarSongsTests {
    @Test func similarSongs_mapsAndClamps() async throws {
        let (client, t) = makeClient()
        t.stub(pathSuffix: "/rest/getSimilarSongs2",
               body: ok(#""similarSongs2":{"song":[{"id":"s1","title":"One","artist":"Aurora Field","duration":201},{"id":"s2","title":"Two"}]}"#))
        let songs = try await client.similarSongs(id: "seed", count: 50)
        let r = try #require(t.requests.last)
        #expect(queryValue(r, "id") == "seed" && queryValue(r, "count") == "50")
        #expect(songs.map(\.id) == ["s1", "s2"] && songs[0].artist == "Aurora Field" && songs[0].duration == 201)

        _ = try await client.similarSongs(id: "seed", count: 9000)
        #expect(t.requests.last.flatMap { queryValue($0, "count") } == "500", "at most 500")
        _ = try await client.similarSongs(id: "seed", count: 0)
        #expect(t.requests.last.flatMap { queryValue($0, "count") } == "1", "at least 1")
        _ = try await client.similarSongs(id: "seed", count: .min)
        #expect(t.requests.last.flatMap { queryValue($0, "count") } == "1")
    }

    @Test(arguments: [#""similarSongs2":{}"#, #""similarSongs2":{"song":[]}"#, #""other":1"#])
    func similarSongs_absentListIsEmpty(_ body: String) async throws {
        let (client, t) = makeClient()
        t.stub(pathSuffix: "/rest/getSimilarSongs2", body: ok(body))
        #expect(try await client.similarSongs(id: "seed", count: 20).isEmpty)
    }
}
