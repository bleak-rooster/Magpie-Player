import Foundation
import Testing
import MagpieCore
@testable import Requests

/// A ready find never holds a song id the library no longer has. Navidrome can re-identify a song after Ready: a
/// scan's move detection merges the just-imported row into an older, missing row of the same recording (seen on the
/// dev stack: `3K5d…` became `71Ad…`). The reconcile pass (and the app, when play or art gets a not-found) looks the
/// find's song up again: by recording MBID, else Y5's path / title + artist + duration match, never by name only.
@Suite struct ReadyFindRefindTests {
    static let rec = recSingleAndAlbum

    /// A ready find (song "find-1") whose first look (in the pass it became ready) is behind it.
    static func ready(_ h: Harness) async throws -> RequestID {
        let id = try await KeepTests.readyFind(h)
        #expect(h.library.state.withLock { $0.existsReads } == ["find-1"], "looked at once it's ready")
        h.library.state.withLock { $0.existsReads = [] }
        h.clock.advance(RequestRunner.refindInterval)
        return id
    }

    /// The pass sees the id gone and takes the recording's song now; the app is told (before, now).
    @Test func reconcileReResolvesByMBID() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await Self.ready(h)
        h.library.state.withLock {
            $0.gone = ["find-1"]
            $0.indexed[Self.rec] = "find-2"
        }

        await h.runner.tick()

        #expect(try #require(await h.request(id)).songId == "find-2")
        #expect(h.refound.withLock { $0.map { "\($0.1)->\($0.2 ?? "nil")" } } == ["find-1->find-2"])
        #expect(try #require(await h.request(id)).state == .ready)
    }

    /// A live id is left alone (and the app isn't told anything).
    @Test func liveIdStays() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await Self.ready(h)
        h.library.state.withLock { $0.indexed[Self.rec] = "find-2" }   // another copy of the recording

        await h.runner.tick()

        #expect(try #require(await h.request(id)).songId == "find-1")
        #expect(h.refound.withLock { $0.isEmpty })
        #expect(h.library.state.withLock { $0.existsReads } == ["find-1"])
    }

    /// Can't tell (the library unreadable): nothing changes.
    @Test func unknownChangesNothing() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await Self.ready(h)
        h.library.state.withLock {
            $0.existsUnknown = true
            $0.indexed[Self.rec] = "find-2"
        }
        await h.runner.tick()
        #expect(try #require(await h.request(id)).songId == "find-1")
        #expect(h.refound.withLock { $0.isEmpty })
    }

    /// Without MusicBrainz tags in the library: Y5's match by Lidarr's track file path, inside the artist folder.
    @Test func fallsBackToThePathMatch() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await Self.ready(h)
        let song = Song(id: "find-3", title: "Other title", artist: "Somebody", album: "Lowlands", duration: 1)
        h.library.state.withLock {
            $0.gone = ["find-1"]
            $0.indexed[Self.rec] = nil
            $0.titled = [(song, NotForMeTests.songPath)]
        }

        h.server.with { $0.songImported = true }   // Lidarr's track file: the path to match
        await h.runner.tick()

        #expect(try #require(await h.request(id)).songId == "find-3")
    }

    /// Never by name only: a song of the same title elsewhere (another path, no duration to compare) isn't taken.
    @Test func neverByNameOnly() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await Self.ready(h)
        let song = Song(id: "find-4", title: "Song", artist: "Aurora Field", album: "Lowlands", duration: 200)
        h.library.state.withLock {
            $0.gone = ["find-1"]
            $0.indexed[Self.rec] = nil
            $0.titled = [(song, NotForMeTests.findPath + "/Other (2020)/01 - Song.mp3")]
        }

        await h.runner.tick()

        #expect(try #require(await h.request(id)).songId == "find-1")
        #expect(h.refound.withLock { $0.isEmpty })
    }

    /// Bounded: one look per find per pass, then backing off while it can't be found; found again later.
    @Test func backsOff() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await Self.ready(h)
        h.library.state.withLock {
            $0.gone = ["find-1"]
            $0.indexed[Self.rec] = nil
        }
        await h.runner.tick()
        await h.runner.tick()
        #expect(h.library.state.withLock { $0.existsReads.count } == 1, "one look, then not before the backoff")

        h.clock.advance(RequestRunner.refindInterval)
        await h.runner.tick()
        #expect(h.library.state.withLock { $0.existsReads.count } == 1, "the wait doubled")
        h.clock.advance(RequestRunner.refindInterval)
        await h.runner.tick()
        #expect(h.library.state.withLock { $0.existsReads.count } == 2)

        h.library.state.withLock { $0.indexed[Self.rec] = "find-2" }
        h.clock.advance(RequestRunner.refindInterval * 4)
        await h.runner.tick()
        #expect(try #require(await h.request(id)).songId == "find-2")
    }

    /// The app's play or art read got a not-found for the find's song: it's looked up again right away (still at
    /// most once per `refindMinInterval`), and the new id comes back.
    @Test func appNotFoundReResolvesNow() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await Self.ready(h)
        h.library.state.withLock {
            $0.gone = ["find-1"]
            $0.indexed[Self.rec] = "find-2"
        }

        #expect(await h.runner.songNotFound("find-1") == "find-2")
        #expect(try #require(await h.request(id)).songId == "find-2")
        #expect(h.refound.withLock { $0.count } == 1)
        // An id no ready find holds: nothing.
        #expect(await h.runner.songNotFound("someone-else") == nil)
    }

    /// The app's not-found is bounded too: a second one at once doesn't look again.
    @Test func appNotFoundIsBounded() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        _ = try await Self.ready(h)
        h.library.state.withLock {
            $0.gone = ["find-1"]
            $0.indexed[Self.rec] = nil
        }
        #expect(await h.runner.songNotFound("find-1") == nil)
        let reads = h.library.state.withLock { $0.titledReads }
        #expect(await h.runner.songNotFound("find-1") == nil)
        #expect(h.library.state.withLock { $0.titledReads } == reads)
    }
}
