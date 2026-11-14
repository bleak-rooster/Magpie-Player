import Foundation
import Testing
import MagpieCore
import MagpieTestSupport
@testable import NavidromeKit

/// Round 27 P (owner, 2026-11-14): `timeOffset` on a stream URL only when asked (D278, D281); D42/D45's rule that
/// AAC and Opus go out without a length estimate is unchanged.
@Suite struct TimeOffsetURLTests {
    private func items(_ url: URL?) -> [String: String] {
        let list = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
        return Dictionary(list.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
    }

    @Test func streamURL_timeOffsetOnlyWhenAsked() async throws {
        let (client, _) = makeClient()
        #expect(items(client.streamURL(songId: "a", maxBitRate: 160, format: "aac"))["timeOffset"] == nil)
        #expect(items(client.streamURL(songId: "a", maxBitRate: 160, format: "aac", timeOffset: nil))["timeOffset"] == nil)
        #expect(items(client.streamURL(songId: "a", maxBitRate: 160, format: "aac", timeOffset: 30))["timeOffset"] == "30")
        #expect(items(client.streamURL(songId: "a", maxBitRate: 160, format: "aac", timeOffset: 0))["timeOffset"] == "0")
        #expect(items(client.streamURL(songId: "a", maxBitRate: 160, format: "aac", timeOffset: -5))["timeOffset"] == "0",
                "a negative offset is the start")
    }

    @Test(arguments: ["aac", "opus"])
    func streamURL_aacOpusStillNoEstimate(_ format: String) async throws {
        let (client, _) = makeClient()
        for offset in [nil, 0, 42] as [Int?] {
            let q = items(client.streamURL(songId: "a", maxBitRate: 128, format: format, timeOffset: offset))
            #expect(q["estimateContentLength"] == nil && q["format"] == format)
        }
        let mp3 = items(client.streamURL(songId: "a", maxBitRate: 320, format: "mp3", timeOffset: 10))
        #expect(mp3["timeOffset"] == "10")
    }

    /// Round 27 P (cause 3 of plan §2.7, shown by `TranscodeIT.mp3OfAVBRFileEndsAtItsLength` on the dev image: MP3 192
    /// and 128 of a VBR source were cut short, -1005, with the estimate): a converted MP3 goes out chunked like AAC and
    /// Opus. Only the original keeps the estimate (its length is exact).
    @Test(arguments: [320, 192, 128])
    func streamURL_mp3NoLongerEstimated(_ rate: Int) async throws {
        let (client, _) = makeClient()
        #expect(items(client.streamURL(songId: "a", maxBitRate: rate, format: "mp3"))["estimateContentLength"] == nil)
        #expect(items(client.streamURL(songId: "a", maxBitRate: nil, format: "raw"))["estimateContentLength"] == "true")
        #expect(items(client.streamURL(songId: "a", maxBitRate: nil, format: nil))["estimateContentLength"] == "true")
    }
}
