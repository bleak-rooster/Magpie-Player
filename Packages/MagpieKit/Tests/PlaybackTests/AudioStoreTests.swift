import Foundation
import Synchronization
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

@Suite final class AudioStoreTests {
    let tmp = FileManager.default.temporaryDirectory.appending(path: "AudioStoreTests-\(UUID().uuidString)")

    deinit { try? FileManager.default.removeItem(at: tmp) }

    func tempFile(bytes: Int) -> URL {
        let incoming = tmp.appending(path: "incoming")
        try! FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        let url = incoming.appending(path: "audio-\(UUID().uuidString).tmp")
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
                != AudioStore.fileName(songId: "s1", quality: .aacMedium, fileExtension: "mp3"))
    }

    @Test func fileExtensionAllowlist() {
        #expect(AudioStore.fileExtension(quality: .original, suffix: "flac", mimeType: nil) == "flac")
        #expect(AudioStore.fileExtension(quality: .original, suffix: "../x", mimeType: "audio/mpeg") == "mp3")
        // Unknown formats are refused, never guessed.
        #expect(AudioStore.fileExtension(quality: .original, suffix: nil, mimeType: "text/html") == nil)
        #expect(AudioStore.fileExtension(quality: .original, suffix: nil, mimeType: "application/octet-stream") == nil)
        #expect(AudioStore.fileExtension(quality: .aacMedium, suffix: "flac", mimeType: nil) == "aac")
        #expect(AudioStore.fileExtension(quality: .mp3Medium, suffix: "flac", mimeType: nil) == "mp3")
        // D45: an Opus preset is an Ogg file whatever the source suffix was.
        for q in [StreamQuality.opusHigh, .opusMedium, .opusLow] {
            #expect(AudioStore.fileExtension(quality: q, suffix: "flac", mimeType: "audio/ogg") == "ogg")
            #expect(AudioStore.fileExtension(quality: q, suffix: nil, mimeType: nil) == "ogg")
        }
        // Original takes Ogg only from a `.opus` source; Vorbis or FLAC in Ogg is refused.
        #expect(AudioStore.fileExtension(quality: .original, suffix: "opus", mimeType: "audio/ogg") == "ogg")
        #expect(AudioStore.fileExtension(quality: .original, suffix: "opus", mimeType: "audio/opus") == "ogg")
        #expect(AudioStore.fileExtension(quality: .original, suffix: "opus", mimeType: nil) == "ogg")
        for suffix in ["ogg", "oga", "flac", nil] as [String?] {
            #expect(AudioStore.fileExtension(quality: .original, suffix: suffix, mimeType: "audio/ogg") == nil, "\(suffix ?? "nil")")
            #expect(AudioStore.fileExtension(quality: .original, suffix: suffix, mimeType: "audio/opus") == nil, "\(suffix ?? "nil")")
        }
    }

    @Test func oggOpusBodyIsStoredAndKeepsItsName() async throws {
        let store = AudioStore(root: tmp, scope: "abc")
        await store.load()
        let e = try await store.add(tempFile(bytes: 300), metadata: meta("o1"), quality: .opusMedium, kind: .download,
                                    reason: .song, fileExtension: "ogg", downloadsLimit: nil)
        #expect(e.fileName == AudioStore.fileName(songId: "o1", quality: .opusMedium, fileExtension: "ogg"))
        #expect(e.quality == .opusMedium)
        #expect(FileManager.default.fileExists(atPath: store.directory.appending(path: e.fileName).path))
        let reloaded = AudioStore(root: tmp, scope: "abc")
        await reloaded.load()
        #expect(await reloaded.entry(songId: "o1")?.fileName == e.fileName)
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
        try await store.addReason(.album("a1"), songIds: ["s1"])
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
        for id in ["s1", "s2", "s3"] { clock.advance(10); try await store.markPlayed(songId: id) }
        #expect(try await store.evictCache(limit: 800, protecting: []) == ["s1"])
        #expect(await store.usage().cacheBytes == 800)
    }

    @Test func evictionSkipsProtectedAndDownloads() async throws {
        let clock = TestClock()
        let store = AudioStore(root: tmp, scope: "abc", now: clock.now); await store.load()
        try await add(store, "d1", bytes: 400, kind: .download, reason: .song, limit: nil)
        for id in ["s1", "s2", "s3"] { clock.advance(10); try await add(store, id, bytes: 400, kind: .cache, reason: nil, limit: nil) }
        #expect(try await store.evictCache(limit: 800, protecting: ["s1"]) == ["s2"])
        let d1 = await store.entry(songId: "d1"), s1 = await store.entry(songId: "s1")
        #expect(d1 != nil && s1 != nil)
    }

    /// Task 13 fix I1: the protected songs are read when the removal runs, not when it was asked for.
    @Test func liveProtectionIsReadAtRemovalTime() async throws {
        let store = AudioStore(root: tmp, scope: "abc"); await store.load()
        for id in ["s1", "s2", "s3"] { try await add(store, id, bytes: 400, kind: .cache, reason: nil, limit: nil) }
        #expect(try await store.removeCache(songIds: ["s1", "s2"], sparing: { ["s1"] }) == ["s2"])
        #expect(try await store.evictCache(limit: 0, protecting: { ["s3"] }) == ["s1"])
        #expect(await store.entries().map(\.songId) == ["s3"])
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
        try await store.addReason(.playlist("p1"), songIds: ["s1"])
        #expect(try await store.removeReason(.album("a1")) == [])
        #expect(try await store.removeReason(.playlist("p1")) == ["s1"])
        #expect(!FileManager.default.fileExists(atPath: store.directory.appending(path: e.fileName).path))
    }

    @Test func replaceStoresNewThenDeletesOld() async throws {
        let store = AudioStore(root: tmp, scope: "abc"); await store.load()
        let old = try await add(store, "s1", bytes: 100, kind: .download, reason: .song, limit: nil)
        let new = try await store.replace(songId: "s1", with: tempFile(bytes: 50), quality: .mp3High, fileExtension: "mp3")
        #expect(new.quality == .mp3High && new.size == 50 && new.reasons == [.song] && new.kind == .download)
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

    @Test func addRefusesAnExtensionOffTheAllowlist() async throws {
        let store = AudioStore(root: tmp, scope: "abc"); await store.load()
        let temp = tempFile(bytes: 10)
        await #expect(throws: AudioStoreError.invalidFile) {
            try await store.add(temp, metadata: self.meta("s1"), quality: .original, kind: .download, reason: .song,
                                fileExtension: "html", downloadsLimit: nil)
        }
        #expect(await store.entries().isEmpty && !FileManager.default.fileExists(atPath: temp.path))
    }

    @Test func promoteChecksTheLimitInOneStep() async throws {
        let store = AudioStore(root: tmp, scope: "abc"); await store.load()
        try await add(store, "c1", bytes: 1000, kind: .cache, reason: nil, limit: nil)
        try await add(store, "c2", bytes: 1000, kind: .cache, reason: nil, limit: nil)
        try await store.promote(songId: "c1", reason: .album("a1"), downloadsLimit: 1500)
        await #expect(throws: AudioStoreError.downloadsFull) {
            try await store.promote(songId: "c2", reason: .album("a1"), downloadsLimit: 1500)
        }
        await #expect(throws: AudioStoreError.unknownSong) {
            try await store.promote(songId: "nope", reason: .song, downloadsLimit: nil)
        }
        #expect(await store.usage() == AudioUsage(downloadBytes: 1000, cacheBytes: 1000))
        #expect(await store.entry(songId: "c1")?.reasons == [.album("a1")])
    }

    /// The app was killed (or the index write failed) after a sidecar was written: the stale index is readable.
    @Test func staleIndexAdoptsSidecarsItIsMissing() async throws {
        let store = AudioStore(root: tmp, scope: "abc"); await store.load()
        try await add(store, "s1", bytes: 100, kind: .download, reason: .song, limit: nil)
        let indexURL = store.directory.appending(path: "index.json")
        let stale = try Data(contentsOf: indexURL)
        try await add(store, "s2", bytes: 100, kind: .download, reason: .album("a1"), limit: nil)
        try await store.addReason(.playlist("p1"), songIds: ["s1"])
        try stale.write(to: indexURL)
        let again = AudioStore(root: tmp, scope: "abc"); await again.load()
        #expect(await again.entry(songId: "s2")?.reasons == [.album("a1")])
        #expect(await again.entry(songId: "s1")?.reasons == [.song, .playlist("p1")], "the newer sidecar wins")
        let reread = AudioStore(root: tmp, scope: "abc"); await reread.load()
        #expect(await reread.entries().count == 2, "the index was rewritten")
    }

    @Test func readableIndexStillDeletesOrphansAndLeftovers() async throws {
        let store = AudioStore(root: tmp, scope: "abc"); await store.load()
        let kept = try await add(store, "s1", bytes: 100, kind: .download, reason: .song, limit: nil)
        let gone = try await add(store, "s2", bytes: 100, kind: .download, reason: .song, limit: nil)
        let dir = store.directory
        let orphanAudio = dir.appending(path: String(repeating: "f", count: 64) + ".mp3")
        let leftover = dir.appending(path: ".index.json.\(UUID().uuidString).tmp")
        let pendingWrite = dir.appending(path: ".pending.json.\(UUID().uuidString).tmp")   // the manager's, mid-write
        try Data(count: 10).write(to: orphanAudio)
        try Data(count: 10).write(to: leftover)
        try Data(count: 10).write(to: pendingWrite)
        // A valid sidecar whose audio is gone.
        let lost = try await add(store, "s3", bytes: 100, kind: .download, reason: .song, limit: nil)
        try FileManager.default.removeItem(at: dir.appending(path: lost.fileName))
        let orphanSidecar = dir.appending(path: lost.fileName + ".json")
        try FileManager.default.removeItem(at: dir.appending(path: gone.fileName + ".json"))   // s2 audio, no sidecar...
        // ...and no index entry either: remove s2 from the index file.
        var json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appending(path: "index.json"))) as? [String: Any])
        var entries = try #require(json["entries"] as? [String: Any]); entries["s2"] = nil; entries["s3"] = nil
        json["entries"] = entries
        try JSONSerialization.data(withJSONObject: json).write(to: dir.appending(path: "index.json"))
        let again = AudioStore(root: tmp, scope: "abc"); await again.load()
        #expect(await again.entries().map(\.songId) == ["s1"])
        for url in [orphanAudio, orphanSidecar, leftover, dir.appending(path: gone.fileName)] {
            #expect(!FileManager.default.fileExists(atPath: url.path), "\(url.lastPathComponent)")
        }
        #expect(FileManager.default.fileExists(atPath: dir.appending(path: kept.fileName).path))
        #expect(FileManager.default.fileExists(atPath: pendingWrite.path), "only the store's own temp files are swept")
    }

    @Test func indexEntryNamingAnotherPathIsDropped() async throws {
        let store = AudioStore(root: tmp, scope: "abc"); await store.load()
        let e = try await add(store, "s1", bytes: 100, kind: .download, reason: .song, limit: nil)
        let dir = store.directory
        try FileManager.default.removeItem(at: dir.appending(path: e.fileName + ".json"))
        var json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appending(path: "index.json"))) as? [String: Any])
        var entries = try #require(json["entries"] as? [String: Any])
        var s1 = try #require(entries["s1"] as? [String: Any])
        s1["fileName"] = "../../evil.mp3"
        entries["s1"] = s1
        entries["other-key"] = s1   // key and song id disagree
        json["entries"] = entries
        try JSONSerialization.data(withJSONObject: json).write(to: dir.appending(path: "index.json"))
        let again = AudioStore(root: tmp, scope: "abc"); await again.load()
        #expect(await again.entries().isEmpty)
        #expect(await again.localFiles().isEmpty)
    }

    @Test func scopeMustBeAnAppMadeId() async {
        #expect(AudioStore.isValidScope("3f2a9c01bd44") && AudioStore.isValidScope("abc_D-1"))
        for bad in ["", "..", "a/b", "../x", ".hidden", String(repeating: "a", count: 65)] {
            #expect(!AudioStore.isValidScope(bad), "\(bad)")
        }
        await #expect(processExitsWith: .failure) {
            _ = AudioStore(root: URL(filePath: NSTemporaryDirectory()), scope: "../escape")
        }
    }

    // MARK: - Fix round 2: fail safe

    /// Every file under the store, relative, with its size: what "nothing changed on disk" compares.
    func snapshot(_ store: AudioStore) -> [String: Int] {
        let base = store.directory.path + "/"
        var out: [String: Int] = [:]
        for case let url as URL in FileManager.default.enumerator(at: store.directory, includingPropertiesForKeys: [.fileSizeKey])! {
            out[String(url.path.dropFirst(base.count))] = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
        }
        return out
    }

    func populated() async throws -> AudioStore {
        let store = AudioStore(root: tmp, scope: "abc"); await store.load()
        try await add(store, "s1", bytes: 100, kind: .download, reason: .song, limit: nil)
        try await add(store, "s2", bytes: 100, kind: .cache, reason: nil, limit: nil)
        try await store.savePlaylist(DownloadedPlaylist(id: "p1", name: "P", coverArtId: nil, songIds: ["s1"], savedAt: Date()))
        return store
    }

    /// Before first unlock: protected files list and unlink but can't be opened, and protected data is unavailable.
    final class Lock: Sendable {
        let locked = Mutex(true)
        let reads = Mutex(0)
        /// Fails `matching` files (default: all) with the error protected data gives before first unlock.
        func reader(_ matching: @escaping @Sendable (URL) -> Bool = { _ in true }) -> @Sendable (URL) throws -> Data {
            { [self] url in
                reads.withLock { $0 += 1 }
                if locked.withLock({ $0 }), matching(url) { throw CocoaError(.fileReadNoPermission) }
                return try Data(contentsOf: url)
            }
        }
        var isAvailable: @Sendable () -> Bool { { [self] in !locked.withLock { $0 } } }
        func unlock() { locked.withLock { $0 = false } }
    }

    @Test func unreadableFilesChangeNothingAndAreRetried() async throws {
        let store = try await populated()
        try Data("garbage".utf8).write(to: store.directory.appending(path: "index.json"))   // forces the sidecar pass
        let before = snapshot(store)
        let lock = Lock()
        let early = AudioStore(root: tmp, scope: "abc", isProtectedDataAvailable: lock.isAvailable, read: lock.reader())
        await early.load()
        #expect(await early.entries().isEmpty)
        #expect(await early.usage() == AudioUsage(downloadBytes: 0, cacheBytes: 0))
        #expect(await early.isReady() == false)
        #expect(snapshot(early) == before, "zero deletions, zero writes")
        lock.unlock()
        await early.protectedDataDidBecomeAvailable()
        #expect(await early.entries().map(\.songId).sorted() == ["s1", "s2"])
        #expect(await early.playlists().map(\.id) == ["p1"])
        #expect(await early.isReady())
    }

    /// The index reads but the sidecars can't: serve the index, touch nothing.
    @Test func unreadableSidecarsKeepTheIndexAndTouchNothing() async throws {
        let store = try await populated()
        let before = snapshot(store)
        let lock = Lock()
        let early = AudioStore(root: tmp, scope: "abc", isProtectedDataAvailable: lock.isAvailable,
                               read: lock.reader { $0.lastPathComponent.hasSuffix(".mp3.json") })
        await early.load()
        #expect(await early.entries().map(\.songId).sorted() == ["s1", "s2"])
        #expect(snapshot(early) == before)
    }

    /// Fix round 3 (N2b): the stand-in index is stale (one sidecar unreadable). Nothing may be decided from it: no
    /// eviction of what is really a download, no demotion of a stored song, and every write says `notReady`.
    @Test func staleStandInIsReadOnly() async throws {
        let store = AudioStore(root: tmp, scope: "abc"); await store.load()
        let s1 = try await add(store, "s1", bytes: 100, kind: .download, reason: .song, limit: nil)
        try await add(store, "s3", bytes: 100, kind: .cache, reason: nil, limit: nil)
        let indexURL = store.directory.appending(path: "index.json")
        let stale = try Data(contentsOf: indexURL)            // says s3 is cache
        try await store.promote(songId: "s3", reason: .album("a1"), downloadsLimit: nil)   // s3 is a download now
        try stale.write(to: indexURL)
        let before = snapshot(store)

        let lock = Lock()
        let early = AudioStore(root: tmp, scope: "abc", isProtectedDataAvailable: lock.isAvailable,
                               read: lock.reader { $0.lastPathComponent == s1.fileName + ".json" })
        await early.load()
        #expect(await early.entry(songId: "s3")?.kind == .cache, "the stand-in is stale")
        await #expect(throws: AudioStoreError.notReady) { try await early.evictCache(limit: 0, protecting: []) }
        let again = tempFile(bytes: 50)
        await #expect(throws: AudioStoreError.notReady) {
            try await early.add(again, metadata: self.meta("s1"), quality: .original, kind: .cache, reason: nil,
                                fileExtension: "mp3", downloadsLimit: nil)
        }
        await #expect(throws: AudioStoreError.notReady) {
            try await early.add(self.tempFile(bytes: 50), metadata: self.meta("s1"), quality: .original, kind: .download,
                                reason: .song, fileExtension: "mp3", downloadsLimit: nil)
        }
        await #expect(throws: AudioStoreError.notReady) { try await early.markPlayed(songId: "s3") }
        await #expect(throws: AudioStoreError.notReady) { try await early.removeAll(kind: .cache) }
        await #expect(throws: AudioStoreError.notReady) { try await early.saveCover(Data([1]), coverArtId: "c") }
        #expect(snapshot(early) == before, "nothing deleted, demoted or written")

        lock.unlock()
        await early.protectedDataDidBecomeAvailable()
        #expect(await early.entry(songId: "s3")?.kind == .download, "the sidecar wins once readable")
        #expect(try await early.evictCache(limit: 0, protecting: []).isEmpty)
    }

    /// Any other read error (here EIO) is not "try later": that file is kept and skipped, the rest reconciles.
    @Test func otherReadErrorsDoNotStallReconcile() async throws {
        let store = try await populated()
        let s1 = try #require(await store.entry(songId: "s1"))
        try Data("garbage".utf8).write(to: store.directory.appending(path: "index.json"))
        let sidecar = store.directory.appending(path: s1.fileName + ".json")
        let sidecarBytes = try Data(contentsOf: sidecar)
        let read: @Sendable (URL) throws -> Data = { url in
            if url.lastPathComponent == s1.fileName + ".json" { throw CocoaError(.fileReadUnknown, userInfo: [NSUnderlyingErrorKey: POSIXError(.EIO)]) }
            return try Data(contentsOf: url)
        }
        let again = AudioStore(root: tmp, scope: "abc", isProtectedDataAvailable: { false }, read: read)
        await again.load()
        #expect(await again.isReady(), "not stalled")
        #expect(await again.entries().map(\.songId) == ["s2"])
        #expect(try Data(contentsOf: sidecar) == sidecarBytes, "kept, not rewritten")
        #expect(FileManager.default.fileExists(atPath: again.directory.appending(path: s1.fileName).path), "audio kept")
        // A cache add can't demote it; a download replaces it with fresh bytes.
        await #expect(throws: AudioStoreError.invalidFile) {
            try await again.add(self.tempFile(bytes: 10), metadata: self.meta("s1"), quality: .original, kind: .cache,
                                reason: nil, fileExtension: "mp3", downloadsLimit: nil)
        }
        #expect(FileManager.default.fileExists(atPath: again.directory.appending(path: s1.fileName).path))
    }

    @Test func pendingRetriesAreThrottled() async throws {
        let store = try await populated()
        try Data("garbage".utf8).write(to: store.directory.appending(path: "index.json"))
        let clock = TestClock()
        let lock = Lock()
        let early = AudioStore(root: tmp, scope: "abc", now: clock.now, isProtectedDataAvailable: lock.isAvailable,
                               retryInterval: 30, read: lock.reader())
        await early.load()
        let afterLoad = lock.reads.withLock { $0 }
        for _ in 0..<5 { _ = await early.entries(); _ = try? await early.markPlayed(songId: "s1") }
        clock.advance(29)
        _ = await early.entries()
        #expect(lock.reads.withLock { $0 } == afterLoad, "no retry inside 30 s")
        clock.advance(1)
        _ = await early.entries()
        #expect(lock.reads.withLock { $0 } > afterLoad, "one retry after 30 s")
        let afterRetry = lock.reads.withLock { $0 }
        _ = await early.entries()
        #expect(lock.reads.withLock { $0 } == afterRetry)
        lock.unlock()
        await early.protectedDataDidBecomeAvailable()   // no wait when protected data arrives
        #expect(await early.isReady())
    }

    @Test func undecodableReasonsBecomeUnknownAndCanBeCleared() async throws {
        let store = AudioStore(root: tmp, scope: "abc"); await store.load()
        let e = try await add(store, "s1", bytes: 100, kind: .download, reason: .song, limit: nil)
        let dir = store.directory
        var json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appending(path: e.fileName + ".json"))) as? [String: Any])
        json["reasons"] = [["someFutureReason": ["_0": "x"]]]
        try JSONSerialization.data(withJSONObject: json).write(to: dir.appending(path: e.fileName + ".json"))
        try Data("garbage".utf8).write(to: dir.appending(path: "index.json"))
        let again = AudioStore(root: tmp, scope: "abc"); await again.load()
        #expect(await again.entry(songId: "s1")?.reasons == [.unknown])
        #expect(try await again.removeReason(.unknown) == ["s1"])
    }

    @Test func undecodableSidecarKeepsItsAudio() async throws {
        let store = try await populated()
        let s1 = try #require(await store.entry(songId: "s1"))
        let dir = store.directory
        try Data("{not json".utf8).write(to: dir.appending(path: s1.fileName + ".json"))
        let index = try Data(contentsOf: dir.appending(path: "index.json"))
        try Data("garbage".utf8).write(to: dir.appending(path: "index.json"))
        let again = AudioStore(root: tmp, scope: "abc"); await again.load()
        let s1Again = await again.entry(songId: "s1"), s2Again = await again.entry(songId: "s2")
        #expect(s1Again == nil && s2Again != nil)
        #expect(FileManager.default.fileExists(atPath: dir.appending(path: s1.fileName).path), "audio kept")
        #expect(FileManager.default.fileExists(atPath: dir.appending(path: s1.fileName + ".json").path), "sidecar kept")
        // With a readable index the entry comes back and its sidecar is healed.
        try index.write(to: dir.appending(path: "index.json"))
        let healed = AudioStore(root: tmp, scope: "abc"); await healed.load()
        #expect(await healed.entry(songId: "s1")?.reasons == [.song])
        let sidecar = try JSONDecoder().decode(AudioEntry.self, from: Data(contentsOf: dir.appending(path: s1.fileName + ".json")))
        #expect(sidecar.songId == "s1")
    }

    /// A sidecar from an older schema (fields missing) still decodes; its size comes from the file.
    @Test func oldSchemaSidecarDecodesAndSizeComesFromDisk() async throws {
        let store = AudioStore(root: tmp, scope: "abc"); await store.load()
        let e = try await add(store, "s1", bytes: 100, kind: .download, reason: .song, limit: nil)
        let dir = store.directory
        let old = #"{"songId":"s1","quality":"original","fileName":"\#(e.fileName)","metadata":{"songId":"s1","title":"Ts1"}}"#
        try Data(old.utf8).write(to: dir.appending(path: e.fileName + ".json"))
        try Data("garbage".utf8).write(to: dir.appending(path: "index.json"))
        let again = AudioStore(root: tmp, scope: "abc"); await again.load()
        let entry = try #require(await again.entry(songId: "s1"))
        #expect(entry.kind == .download && entry.size == 100 && entry.metadata.title == "Ts1")
        #expect(await again.usage().downloadBytes == 100)
    }
}
