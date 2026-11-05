import Foundation
import Testing
import MagpieCore
@testable import Requests

/// Round 15 C3 (owner item 7, D137, D138): a rejected find leaves the owner's playlists: which positions go, what is
/// said, the saved clean-ups and their short history.
@Suite struct FindCleanupTests {
    @Test func everyEntryOfTheFindIsRemovedHighestFirstOthersUntouched() {
        let list = ["x", "f1", "y", "f1", "f2", "z"]
        let indexes = FindCleanups.indexesToRemove(["f1", "f2"], in: list)
        #expect(indexes == [4, 3, 1], "duplicates too, from the highest index down")
        var after = list
        for i in indexes { after.remove(at: i) }   // applied one at a time, highest first, as the server may
        #expect(after == ["x", "y", "z"])
        #expect(FindCleanups.indexesToRemove(["f9"], in: list).isEmpty)
    }

    @Test func theMessageNamesTheSongAndThePlaylists() {
        #expect(FindCleanups.message(title: "Song", playlists: ["Road Trip", "Chill"])
                == "Removed \u{201C}Song\u{201D} from 2 playlists: Road Trip, Chill")
        #expect(FindCleanups.message(title: "Song", playlists: ["Road Trip"])
                == "Removed \u{201C}Song\u{201D} from Road Trip")
        #expect(FindCleanups.message(title: "Song", playlists: []) == nil)
        let many = FindCleanups.message(title: "Song", playlists: ["A", "B", "C", "D", "E"])
        #expect(many == "Removed \u{201C}Song\u{201D} from 5 playlists: A, B, C and 2 more")
    }

    @Test func cleanupsAreSavedAndErasedWithTheRequests() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "FindCleanup-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = FindCleanupStore.defaultURL(in: dir, instance: "lidarr-a")
        let job = FindCleanup(requestId: RequestID(), title: "Song", songIds: ["f1", "f2"], createdAt: Date())
        try await FindCleanupStore(fileURL: url).save([job])
        let loaded = try await FindCleanupStore(fileURL: url).load()
        #expect(loaded == [job])
        RequestStore.eraseAll(in: dir)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func theHistoryKeepsOnlyTheLatestFinished() {
        let now = Date()
        var jobs = (0..<30).map { i in
            var j = FindCleanup(requestId: RequestID(), title: "S\(i)", songIds: ["f\(i)"], createdAt: now)
            j.finishedAt = now.addingTimeInterval(TimeInterval(i))
            return j
        }
        jobs.append(FindCleanup(requestId: RequestID(), title: "open", songIds: ["o"], createdAt: now))
        let trimmed = FindCleanups.trimmed(jobs)
        #expect(trimmed.filter { $0.finishedAt == nil }.count == 1, "unfinished ones are never dropped")
        #expect(trimmed.filter { $0.finishedAt != nil }.count == FindCleanups.historyLimit)
        #expect(trimmed.contains { $0.title == "S29" } && !trimmed.contains { $0.title == "S0" })
    }
}
