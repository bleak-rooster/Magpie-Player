import Foundation
import Testing
import MagpieCore
@testable import Playback

/// Round 13 item 7: a cached song's copy at the wrong quality is swapped for one at the right quality. Only a cache
/// entry still at the quality it was fetched from is replaced; a download never is; the old file goes only after the
/// new one is stored.
@Suite final class CacheQualityStoreTests {
    let tmp = FileManager.default.temporaryDirectory.appending(path: "CacheQualityStoreTests-\(UUID().uuidString)")

    deinit { try? FileManager.default.removeItem(at: tmp) }

    func tempFile(bytes: Int) -> URL {
        let incoming = tmp.appending(path: "incoming")
        try! FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        let url = incoming.appending(path: "audio-\(UUID().uuidString).tmp")
        try! Data(count: bytes).write(to: url)
        return url
    }

    func meta(_ id: String) -> AudioMetadata {
        AudioMetadata(Song(id: id, title: "T\(id)", artist: "A", album: "Album", albumId: "a1", duration: 200, suffix: "flac"))
    }

    func addCached(_ store: AudioStore, _ id: String, quality: StreamQuality = .opusMedium) async throws -> AudioEntry {
        try await store.add(tempFile(bytes: 100), metadata: meta(id), quality: quality, kind: .cache, reason: nil,
                            fileExtension: "ogg", downloadsLimit: nil)
    }

    @Test func replacesACacheEntryAtTheExpectedQuality() async throws {
        let store = AudioStore(root: tmp, scope: "abc")
        let old = try await addCached(store, "s1")
        let incoming = tempFile(bytes: 300)
        let swap = try #require(try await store.replaceCache(songId: "s1", from: .opusMedium, with: incoming,
                                                             quality: .original, fileExtension: "flac"))
        let new = swap.entry
        #expect(new.kind == .cache && new.quality == .original && new.size == 300)
        #expect(new.fileName == AudioStore.fileName(songId: "s1", quality: .original, fileExtension: "flac"))
        #expect(await store.entry(songId: "s1") == new)
        let dir = store.directory
        #expect(FileManager.default.fileExists(atPath: dir.appending(path: new.fileName).path))
        #expect(!FileManager.default.fileExists(atPath: incoming.path))
        // Review M1: the old audio stays (its sidecar goes) until the caller knows playback doesn't hold it.
        #expect(swap.oldFileName == old.fileName)
        #expect(FileManager.default.fileExists(atPath: dir.appending(path: old.fileName).path))
        #expect(!FileManager.default.fileExists(atPath: dir.appending(path: old.fileName + ".json").path))
        await store.removeUnreferencedAudio(fileName: old.fileName)
        #expect(!FileManager.default.fileExists(atPath: dir.appending(path: old.fileName).path), "the old file goes")
        // A file an entry still names is never removed this way.
        await store.removeUnreferencedAudio(fileName: new.fileName)
        #expect(FileManager.default.fileExists(atPath: dir.appending(path: new.fileName).path))
        // A reload agrees: one entry, at the new quality.
        let reloaded = AudioStore(root: tmp, scope: "abc")
        await reloaded.load()
        #expect(await reloaded.entry(songId: "s1")?.quality == .original)
        #expect(await reloaded.entries().count == 1)
    }

    /// Killed before the old audio was removed: the next load finds it with no sidecar and no entry, and removes it.
    @Test func anOldCopyLeftByACrashIsSweptOnLoad() async throws {
        let store = AudioStore(root: tmp, scope: "abc")
        let old = try await addCached(store, "s1")
        _ = try #require(try await store.replaceCache(songId: "s1", from: .opusMedium, with: tempFile(bytes: 300),
                                                     quality: .original, fileExtension: "flac"))
        let reloaded = AudioStore(root: tmp, scope: "abc")
        await reloaded.load()
        #expect(!FileManager.default.fileExists(atPath: store.directory.appending(path: old.fileName).path))
        #expect(await reloaded.entry(songId: "s1")?.quality == .original)
    }

    @Test func neverReplacesADownload() async throws {
        let store = AudioStore(root: tmp, scope: "abc")
        _ = try await addCached(store, "s1")
        try await store.promote(songId: "s1", reason: .song, downloadsLimit: nil)   // saved on purpose meanwhile
        let before = try #require(await store.entry(songId: "s1"))
        let incoming = tempFile(bytes: 300)
        let result = try await store.replaceCache(songId: "s1", from: .opusMedium, with: incoming, quality: .original,
                                                  fileExtension: "flac")
        #expect(result == nil)
        #expect(await store.entry(songId: "s1") == before)
        #expect(FileManager.default.fileExists(atPath: store.directory.appending(path: before.fileName).path))
        #expect(!FileManager.default.fileExists(atPath: incoming.path), "the fetched file is discarded")
    }

    @Test func leavesAnEntryWhoseQualityChangedOrThatWentAway() async throws {
        let store = AudioStore(root: tmp, scope: "abc")
        let kept = try await addCached(store, "s1", quality: .aacHigh)
        #expect(try await store.replaceCache(songId: "s1", from: .opusMedium, with: tempFile(bytes: 300),
                                             quality: .original, fileExtension: "flac") == nil)
        #expect(await store.entry(songId: "s1") == kept)
        #expect(try await store.replaceCache(songId: "gone", from: .opusMedium, with: tempFile(bytes: 300),
                                             quality: .original, fileExtension: "flac") == nil)
    }

    @Test func refusesAnExtensionOffTheAllowlist() async throws {
        let store = AudioStore(root: tmp, scope: "abc")
        let kept = try await addCached(store, "s1")
        await #expect(throws: AudioStoreError.invalidFile) {
            try await store.replaceCache(songId: "s1", from: .opusMedium, with: self.tempFile(bytes: 300),
                                         quality: .original, fileExtension: "exe")
        }
        #expect(await store.entry(songId: "s1") == kept)
    }
}
