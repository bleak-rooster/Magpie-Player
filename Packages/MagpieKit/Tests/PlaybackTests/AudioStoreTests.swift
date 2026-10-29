import Foundation
import Testing
import MagpieCore
@testable import Playback

/// A clock the test moves by hand; starts at 0.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 0)
    func advance(_ seconds: TimeInterval) { lock.withLock { current += seconds } }
    var now: @Sendable () -> Date { { [self] in lock.withLock { current } } }
}

@Suite struct AudioStoreTests {
    let tmp = FileManager.default.temporaryDirectory.appending(path: "AudioStoreTests-\(UUID().uuidString)")

    func tempFile(bytes: Int) -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "audio-\(UUID().uuidString).tmp")
        try! Data(count: bytes).write(to: url)
        return url
    }

    func meta(_ id: String, album: String = "a1") -> AudioMetadata {
        AudioMetadata(Song(id: id, title: "T\(id)", artist: "A", album: album, albumId: album, duration: 200))
    }

    @discardableResult
    func add(_ store: AudioStore, _ id: String, bytes: Int, kind: AudioKind, reason: DownloadReason?,
             limit: Int64?, file: URL? = nil) async throws -> AudioEntry {
        try await store.add(file ?? tempFile(bytes: bytes), metadata: meta(id), quality: .original, kind: kind,
                            reason: reason, fileExtension: "mp3", downloadsLimit: limit)
    }

    @Test func fileNameIsHashNotServerString() {
        let name = AudioStore.fileName(songId: "../../etc/passwd", quality: .original, fileExtension: "mp3")
        #expect(name.wholeMatch(of: /[0-9a-f]{64}\.mp3/) != nil)
        #expect(AudioStore.fileName(songId: "s1", quality: .original, fileExtension: "mp3")
                != AudioStore.fileName(songId: "s1", quality: .aac160, fileExtension: "mp3"))
    }

    @Test func fileExtensionAllowlist() {
        #expect(AudioStore.fileExtension(quality: .original, suffix: "flac", mimeType: nil) == "flac")
        #expect(AudioStore.fileExtension(quality: .original, suffix: "../x", mimeType: "audio/mpeg") == "mp3")
        #expect(AudioStore.fileExtension(quality: .original, suffix: "opus", mimeType: "audio/ogg") == "mp3")
        #expect(AudioStore.fileExtension(quality: .original, suffix: nil, mimeType: "text/html") == "mp3")
        #expect(AudioStore.fileExtension(quality: .aac160, suffix: "flac", mimeType: nil) == "aac")
        #expect(AudioStore.fileExtension(quality: .mp3_192, suffix: "flac", mimeType: nil) == "mp3")
    }

    @Test func addMovesFileAndExcludesFromBackup() async throws {
        let store = AudioStore(root: tmp, scope: "abc"); await store.load()
        let temp = tempFile(bytes: 1000)
        let e = try await add(store, "s1", bytes: 1000, kind: .download, reason: .song, limit: nil, file: temp)
        #expect(e.size == 1000 && e.kind == .download && e.reasons == [.song])
        let url = store.directory.appending(path: e.fileName)
        #expect(FileManager.default.fileExists(atPath: url.path) && !FileManager.default.fileExists(atPath: temp.path))
        #expect(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        #expect(try store.directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        #expect(store.directory.path.hasSuffix("/Magpie/Audio/abc"))
        #expect(await store.localFiles() == ["s1": url])
    }

    @Test func oneEntryPerSong() async throws {
        let store = AudioStore(root: tmp, scope: "abc"); await store.load()
        try await add(store, "s1", bytes: 400, kind: .cache, reason: nil, limit: nil)
        try await add(store, "s1", bytes: 400, kind: .cache, reason: nil, limit: nil)
        #expect(await store.entries().count == 1)
        await store.addReason(.album("a1"), songIds: ["s1"])
        let kind = await store.entry(songId: "s1")?.kind, usage = await store.usage()
        #expect(kind == .download && usage == AudioUsage(downloadBytes: 400, cacheBytes: 0))
    }

    @Test func downloadsLimitRefusesWithoutEvicting() async throws {
        let store = AudioStore(root: tmp, scope: "abc"); await store.load()
        try await add(store, "s1", bytes: 1000, kind: .download, reason: .song, limit: 1500)
        try await add(store, "c1", bytes: 300, kind: .cache, reason: nil, limit: nil)
        let temp = tempFile(bytes: 1000)
        await #expect(throws: AudioStoreError.downloadsFull) {
            try await add(store, "s2", bytes: 1000, kind: .download, reason: .song, limit: 1500, file: temp)
        }
        #expect(await store.entries().map(\.songId).sorted() == ["c1", "s1"])
        #expect(await store.usage() == AudioUsage(downloadBytes: 1000, cacheBytes: 300))
        #expect(!FileManager.default.fileExists(atPath: temp.path))
    }

    @Test func cacheEvictsLeastRecentlyPlayedFirst() async throws {
        let clock = TestClock()
        let store = AudioStore(root: tmp, scope: "abc", now: clock.now); await store.load()
        for id in ["s1", "s2", "s3"] { try await add(store, id, bytes: 400, kind: .cache, reason: nil, limit: nil) }
        for id in ["s1", "s2", "s3"] { clock.advance(10); await store.markPlayed(songId: id) }
        #expect(await store.evictCache(limit: 800, protecting: []) == ["s1"])
        #expect(await store.usage().cacheBytes == 800)
    }

    @Test func evictionSkipsProtectedAndDownloads() async throws {
        let clock = TestClock()
        let store = AudioStore(root: tmp, scope: "abc", now: clock.now); await store.load()
        try await add(store, "d1", bytes: 400, kind: .download, reason: .song, limit: nil)
        for id in ["s1", "s2", "s3"] { clock.advance(10); try await add(store, id, bytes: 400, kind: .cache, reason: nil, limit: nil) }
        #expect(await store.evictCache(limit: 800, protecting: ["s1"]) == ["s2"])
        let d1 = await store.entry(songId: "d1"), s1 = await store.entry(songId: "s1")
        #expect(d1 != nil && s1 != nil)
    }

    @Test func corruptIndexRebuildsFromSidecars() async throws {
        let store = AudioStore(root: tmp, scope: "abc"); await store.load()
        try await add(store, "s1", bytes: 100, kind: .download, reason: .song, limit: nil)
        try Data("garbage".utf8).write(to: store.directory.appending(path: "index.json"))
        let orphan = store.directory.appending(path: String(repeating: "f", count: 64) + ".mp3")
        try Data(count: 10).write(to: orphan)
        let again = AudioStore(root: tmp, scope: "abc"); await again.load()
        #expect(await again.entry(songId: "s1")?.reasons == [.song])
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        #expect((try? JSONSerialization.jsonObject(with: Data(contentsOf: again.directory.appending(path: "index.json")))) != nil)
    }

    @Test func reasonsRemoveDownloadOnlyWhenEmpty() async throws {
        let store = AudioStore(root: tmp, scope: "abc"); await store.load()
        let e = try await add(store, "s1", bytes: 100, kind: .download, reason: .album("a1"), limit: nil)
        await store.addReason(.playlist("p1"), songIds: ["s1"])
        #expect(await store.removeReason(.album("a1")) == [])
        #expect(await store.removeReason(.playlist("p1")) == ["s1"])
        #expect(!FileManager.default.fileExists(atPath: store.directory.appending(path: e.fileName).path))
    }

    @Test func replaceStoresNewThenDeletesOld() async throws {
        let store = AudioStore(root: tmp, scope: "abc"); await store.load()
        let old = try await add(store, "s1", bytes: 100, kind: .download, reason: .song, limit: nil)
        let new = try await store.replace(songId: "s1", with: tempFile(bytes: 50), quality: .mp3_320, fileExtension: "mp3")
        #expect(new.quality == .mp3_320 && new.size == 50 && new.reasons == [.song] && new.kind == .download)
        #expect(!FileManager.default.fileExists(atPath: store.directory.appending(path: old.fileName).path))
        #expect(FileManager.default.fileExists(atPath: store.directory.appending(path: new.fileName).path))
        await #expect(throws: AudioStoreError.unknownSong) {
            try await store.replace(songId: "nope", with: tempFile(bytes: 1), quality: .original, fileExtension: "mp3")
        }
    }

    @Test func coverSavedByHashedName() async throws {
        let store = AudioStore(root: tmp, scope: "abc"); await store.load()
        try await store.saveCover(Data([1, 2, 3]), coverArtId: "../al-1")
        let url = try #require(await store.coverURL(coverArtId: "../al-1"))
        #expect(url.lastPathComponent.wholeMatch(of: /[0-9a-f]{64}\.jpg/) != nil && url.deletingLastPathComponent().lastPathComponent == "covers")
        #expect(await store.coverURL(coverArtId: "al-2") == nil)
    }

    @Test func eraseScopeRemovesDirectory() async throws {
        let store = AudioStore(root: tmp, scope: "abc"); await store.load()
        try await add(store, "s1", bytes: 10, kind: .download, reason: .song, limit: nil)
        await store.eraseScope()
        #expect(!FileManager.default.fileExists(atPath: store.directory.path))
        #expect(await store.entries().isEmpty)
    }
}
