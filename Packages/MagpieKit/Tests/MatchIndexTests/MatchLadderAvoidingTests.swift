import Foundation
import MagpieCore
import Testing
@testable import MatchIndex

private let artist = MBID("4d8175ea-cc33-4565-8a8e-6b0f6c7a3f11")!
private let rec = MBID("20a2961b-d8e8-481c-bd5b-abb38a2850ad")!

private func song(_ id: String, _ title: String = "Song", _ d: TimeInterval = 200, rec: MBID? = nil,
                  artistMBID: MBID? = nil, isrcs: [String] = []) -> Song {
    Song(id: id, title: title, artist: "Aurora Field", album: "First Light", duration: d, recordingMBID: rec,
         artistMBID: artistMBID, isrcs: isrcs)
}

/// Round 26 K2 (owner, 2026-11-10; K1 re-review m1): the direct ladder prefers a library copy outside Discover on every
/// tier, as `songId(recording:avoiding:)` does on the first (D259). The index doesn't keep a song's library, so the
/// caller names the ids it knows are Discover copies; with none named (the default), every caller (Try, search, charts)
/// gets exactly what it got before.
@Suite struct MatchLadderAvoidingTests {
    private let flow: (String) -> Bool = { $0 == "flow" }

    @Test func avoiding_recordingTierTakesTheOtherCopy() {
        let index = MatchIndex(songs: [song("flow", rec: rec), song("main", rec: rec)])
        let r = ExternalRecording(recordingMBID: rec, title: "Song", artist: "Aurora Field", duration: 200, source: .listenBrainz)
        #expect(index.librarySong(for: r) == "flow", "unchanged without a preference")
        #expect(index.librarySong(for: r, avoiding: flow) == "main")
        #expect(index.match(r, avoiding: flow)?.confidence == 1.0)
    }

    @Test func avoiding_isrcTierTakesTheOtherCopy() {
        let index = MatchIndex(songs: [song("flow", isrcs: ["GBAAA0000001"]), song("main", isrcs: ["gbaaa0000001"])])
        let r = ExternalRecording(title: "Other", artist: "Someone", isrcs: ["GBAAA0000001"], source: .listenBrainz)
        #expect(index.librarySong(for: r) == "flow")
        #expect(index.librarySong(for: r, avoiding: flow) == "main")
        #expect(index.match(r, avoiding: flow)?.confidence == 0.95)
    }

    @Test func avoiding_artistMBIDAndTitleTierTakesTheOtherCopy() {
        let index = MatchIndex(songs: [song("flow", artistMBID: artist), song("main", "Song", 201, artistMBID: artist)])
        let r = ExternalRecording(artistMBID: artist, title: "Song", artist: "Aurora Field", duration: 200, source: .lidarr)
        #expect(index.librarySong(for: r) == "flow")
        #expect(index.librarySong(for: r, avoiding: flow) == "main")
        #expect(index.match(r, avoiding: flow)?.confidence == 0.9)
    }

    @Test func avoiding_artistAndTitleTiersTakeTheOtherCopy() {
        let index = MatchIndex(songs: [song("flow"), song("main", "Song", 199)])
        let timed = ExternalRecording(title: "Song", artist: "Aurora Field", duration: 200, source: .lidarr)
        #expect(index.librarySong(for: timed) == "flow")
        #expect(index.librarySong(for: timed, avoiding: flow) == "main")
        #expect(index.match(timed, avoiding: flow)?.confidence == 0.8)

        let untimed = MatchIndex(songs: [song("flow", "Song", 0), song("main", "Song", 0)])
        let r = ExternalRecording(title: "Song", artist: "Aurora Field", duration: 200, source: .lidarr)
        #expect(untimed.match(r)?.songId == "flow")
        #expect(untimed.match(r, avoiding: flow)?.songId == "main" && untimed.match(r, avoiding: flow)?.confidence == 0.6)
        #expect(untimed.librarySong(for: r, avoiding: flow) == nil, "two by name only is still ambiguous")
    }

    /// The only copy is a Discover copy: it is still the answer (as `songId(recording:avoiding:)`); the merge then drops it
    /// by its library after `getSong`.
    @Test func avoiding_onlyCopyIsStillFound() {
        let index = MatchIndex(songs: [song("flow", rec: rec, artistMBID: artist, isrcs: ["GBAAA0000001"])])
        for r in [ExternalRecording(recordingMBID: rec, title: "X", artist: "Y", source: .lidarr),
                  ExternalRecording(title: "X", artist: "Y", isrcs: ["GBAAA0000001"], source: .lidarr),
                  ExternalRecording(artistMBID: artist, title: "Song", artist: "Y", duration: 200, source: .lidarr),
                  ExternalRecording(title: "Song", artist: "Aurora Field", duration: 200, source: .lidarr)] {
            #expect(index.librarySong(for: r, avoiding: { _ in true }) == "flow")
        }
    }

    /// The default changes nothing: a seeded sweep of indexes and recordings answers the same with and without
    /// `avoiding: { _ in false }` (Try and every other caller keep their behaviour).
    @Test func avoiding_defaultChangesNothing() {
        var rng = SeededRandom(seed: 26)
        let titles = ["Song", "Song (Radio Edit)", "Other", "Halo (Live)"]
        for _ in 0..<300 {
            let songs = (0..<Int.random(in: 1...6, using: &rng)).map { i in
                song("s\(i)", titles.randomElement(using: &rng)!, [0, 198, 200, 203, 240].randomElement(using: &rng)!,
                     rec: Bool.random(using: &rng) ? rec : nil, artistMBID: Bool.random(using: &rng) ? artist : nil,
                     isrcs: Bool.random(using: &rng) ? ["GBAAA0000001"] : [])
            }
            let index = MatchIndex(songs: songs)
            let durations: [TimeInterval?] = [nil, 200, 230]
            let r = ExternalRecording(recordingMBID: Bool.random(using: &rng) ? rec : nil,
                                      artistMBID: Bool.random(using: &rng) ? artist : nil,
                                      title: titles.randomElement(using: &rng)!, artist: "Aurora Field",
                                      duration: durations.randomElement(using: &rng)!,
                                      isrcs: Bool.random(using: &rng) ? ["GBAAA0000001"] : [], source: .listenBrainz)
            #expect(index.librarySong(for: r) == index.librarySong(for: r, avoiding: { _ in false }))
            #expect(index.match(r)?.songId == index.match(r, avoiding: { _ in false })?.songId)
            #expect(index.match(r)?.confidence == index.match(r, avoiding: { _ in false })?.confidence)
        }
    }
}

/// A small seeded generator (SplitMix64), so the sweep is the same on every run.
private struct SeededRandom: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
