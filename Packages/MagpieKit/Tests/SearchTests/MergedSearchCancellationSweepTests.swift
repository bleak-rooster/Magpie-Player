import Foundation
import MagpieCore
import MatchIndex
import Testing
@testable import Search

/// Crash hunt 3: the merged search (`async let` library + a task group over the outside sources, each under its own
/// deadline race), cancelled at seeded random points while the library and the sources answer after random delays and
/// some fail. Never a trap, a continuation resumed twice or never (the run must return), or a band in arrival order: a
/// run either returns exactly what the uncancelled run returns, or nothing it shouldn't.
@Suite struct MergedSearchCancellationSweepTests {
    struct Rng: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    final class Delays: @unchecked Sendable {
        private let lock = NSLock()
        private var rng: Rng
        init(seed: UInt64) { rng = Rng(state: seed) }
        func next(_ most: Int) -> Int { lock.lock(); defer { lock.unlock() }; return Int.random(in: 0...most, using: &rng) }
    }

    private static func ext(_ s: Int, _ i: Int) -> ExternalRecording {
        ExternalRecording(recordingMBID: nil, title: "Song \(s).\(i)", artist: "Artist \(s)", source: .listenBrainz)
    }

    /// Four sources, each with its own songs, albums and artists (some repeated across sources, so the merge keeps the
    /// first source's row), one failing; the library answers with one song.
    private static func search(_ delays: Delays, maxMicros: Int) -> MergedSearch {
        let sources = (0..<4).map { s in
            MergedSearch.Source(timeout: .seconds(30)) { _ in
                try await Task.sleep(for: .microseconds(delays.next(maxMicros)))
                if s == 2 { throw URLError(.timedOut) }
                return hits(s)
            }
        }
        let library = Self.library
        return MergedSearch(library: { _ in
            try await Task.sleep(for: .microseconds(delays.next(maxMicros)))
            return library
        }, sources: sources, index: { .empty })
    }

    private static func hits(_ s: Int) -> ExternalHits {
        ExternalHits(songs: (0..<4).map { ext(s, $0) } + [ext(0, 0)],
                     albums: (0..<3).map { NotYetAlbum(title: "Album \(s).\($0)", artist: "Artist \(s)") },
                     artists: [NotYetArtist(name: "Artist \(s)"), NotYetArtist(name: "Artist 0")])
    }

    private static let library = LibrarySearchResult(songs: [Song(id: "lib", title: "Harbour", artist: "Corin", album: "S",
                                                                  duration: 1)])

    /// Every answer a run cut short may give: the library answered or not, and any subset of the sources that can
    /// answer (source 2 always fails), merged in source order.
    private static let possibleMerges: [SearchSections] = {
        var all: [SearchSections] = []
        for mask in 0..<8 {
            let answered: Set<Int> = Set([0, 1, 3].enumerated().filter { mask & (1 << $0.offset) != 0 }.map(\.element))
            let outside = (0..<4).map { answered.contains($0) ? hits($0) : ExternalHits() }
            for lib in [library, LibrarySearchResult()] {
                all.append(MergedSearch.merge(query: "harbour", library: lib, outside: outside, index: .empty))
            }
        }
        return all
    }()

    @Test func cancelledAnywhereReturnsTheWholeAnswerOrNothingWrong() async throws {
        let expected = try await Self.search(Delays(seed: 1), maxMicros: 0).runReportingLibraryFailure("harbour")
        #expect(expected.notYet.songs.first == Self.ext(0, 0), "source order, not arrival order")
        var rng = Rng(state: 0x5EA)
        var outcomes = (whole: 0, cancelled: 0)
        for round in 0..<300 {
            let search = Self.search(Delays(seed: UInt64(round)), maxMicros: 2000)
            let task = Task { try await search.runReportingLibraryFailure("harbour") }
            switch Int.random(in: 0..<3, using: &rng) {
            case 0: break
            case 1: for _ in 0..<Int.random(in: 1...50, using: &rng) { await Task.yield() }
            default: try? await Task.sleep(for: .microseconds(Int.random(in: 0...4000, using: &rng)))
            }
            task.cancel()
            switch await task.result {
            case .success(let found):
                if found == expected {
                    outcomes.whole += 1
                } else {
                    // Cut short: exactly the merge of the sources that answered (a cancelled one adds nothing), in
                    // source order, with the library's rows whole or absent; never a mix in arrival order.
                    outcomes.cancelled += 1
                    #expect(Self.possibleMerges.contains(found), "round \(round): not the merge of any set of sources")
                }
            case .failure(let error):
                outcomes.cancelled += 1
                #expect(error is CancellationError, "round \(round): \(error)")
            }
        }
        #expect(outcomes.whole > 0 && outcomes.cancelled > 0, "\(outcomes)")
    }

    /// The deadline race alone: the work, the deadline and the cancel finishing in any order resume the caller once.
    @Test func deadlineRaceResumesOnceWhateverFinishesFirst() async {
        var rng = Rng(state: 0xDEAD)
        for round in 0..<400 {
            let work = Int.random(in: 0...1500, using: &rng), limit = Int.random(in: 0...1500, using: &rng)
            let task = Task {
                try await MergedSearch.withDeadline(.microseconds(limit), sleep: { try await Task.sleep(for: $0) }) {
                    try await Task.sleep(for: .microseconds(work))
                    return round
                }
            }
            if Bool.random(using: &rng) { try? await Task.sleep(for: .microseconds(Int.random(in: 0...1500, using: &rng))) }
            if Bool.random(using: &rng) { task.cancel() }
            switch await task.result {
            case .success(let value): #expect(value == round)
            case .failure(let error): #expect(error is CancellationError || error is SearchTimedOut, "\(error)")
            }
        }
    }
}
