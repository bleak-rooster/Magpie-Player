import Foundation
import MagpieTestSupport
import Synchronization
import Testing
import MagpieCore
@testable import Playback

/// A reader that fails some files with the errors a phone's disk can give. Decided per path from the seed, so a
/// file fails the same way on every read in one pass.
final class FaultyReader: Sendable {
    let failing: Mutex<[String: Int32]> = Mutex([:])
    let enabled = Mutex(true)
    func reader() -> @Sendable (URL) throws -> Data {
        { [self] url in
            if enabled.withLock({ $0 }), let code = failing.withLock({ $0[url.lastPathComponent] }) {
                if code == EPERM { throw CocoaError(.fileReadNoPermission) }
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
            }
            return try Data(contentsOf: url)
        }
    }
}

/// Hunt 2: seeded, deterministic fuzzing of the store's files (index, sidecars, playlists), its reads (permission,
/// EIO, disk-full) and its writes (a read-only directory), kill-mid-write leftovers, a directory replaced by a file,
/// symlinks, quota edges and concurrency storms. Invariants: no trap; a download is never deleted unless the user
/// removed it; quotas hold; no download is left with no reason.
@Suite(.serialized) final class StoreFuzzTests {
    let tmp = FileManager.default.temporaryDirectory.appending(path: "StoreFuzzTests-\(UUID().uuidString)")
    deinit {
        // Undo any read-only directory before cleaning up.
        if let e = FileManager.default.enumerator(atPath: tmp.path) {
            for case let p as String in e { chmod(tmp.appending(path: p).path, 0o755) }
        }
        try? FileManager.default.removeItem(at: tmp)
    }

    func temp(_ bytes: Int) -> URL {
        let dir = tmp.appending(path: "incoming")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: UUID().uuidString)
        try! Data(count: bytes).write(to: url)
        return url
    }

    static func meta(_ id: String) -> AudioMetadata {
        AudioMetadata(Song(id: id, title: "T\(id)", artist: "A", album: "B", albumId: "al", duration: 100))
    }

    static let reasons: [DownloadReason] = [.song, .album("al"), .playlist("p1"), .favourites]

    /// Corruptions applied to one file's bytes.
    static func mangle(_ data: Data, _ rng: inout SeededRNG) -> Data {
        switch Int.random(in: 0..<9, using: &rng) {
        case 0: return Data()
        case 1: return data.prefix(Int.random(in: 0...max(0, data.count), using: &rng))
        case 2: return Data((0..<Int.random(in: 1..<200, using: &rng)).map { _ in UInt8.random(in: 0...255, using: &rng) })
        case 3, 4:
            // Hostile numbers in otherwise valid JSON: sizes that overflow when summed, negatives, empty reasons.
            guard var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return data }
            let sizes: [Int64] = [.max, .max - 1, .min, -1, 0, 1 << 62]
            if obj["size"] != nil { obj["size"] = NSNumber(value: sizes.randomElement(using: &rng)!) }
            if obj["reasons"] != nil, Bool.random(using: &rng) { obj["reasons"] = [] }
            if obj["kind"] != nil, Bool.random(using: &rng) { obj["kind"] = ["download", "cache", "weird"].randomElement(using: &rng)! }
            if var entries = obj["entries"] as? [String: Any] {
                for (k, v) in entries {
                    guard var e = v as? [String: Any] else { continue }
                    e["size"] = NSNumber(value: sizes.randomElement(using: &rng)!)
                    if Bool.random(using: &rng) { e["reasons"] = [] }
                    entries[k] = e
                }
                obj["entries"] = entries
            }
            return (try? JSONSerialization.data(withJSONObject: obj)) ?? data
        case 5: return data + Data("garbage".utf8)
        case 6: return Data(repeating: UInt8(ascii: "["), count: 10_000)   // deep nesting
        default: return data
        }
    }

    /// Builds a store with `count` songs and a playlist, then damages the files. Returns the store directory and the
    /// download audio names left pristine (audio and sidecar untouched): those must survive any reconcile.
    func damagedStore(seed: UInt64, count: Int) async throws -> (dir: URL, pristine: Set<String>, rng: SeededRNG) {
        var rng = SeededRNG(seed: seed)
        let root = tmp.appending(path: "case-\(seed)")
        let store = AudioStore(root: root, scope: "s")
        await store.load()
        for i in 0..<count {
            let kind: AudioKind = Bool.random(using: &rng) ? .download : .cache
            try await store.add(temp(Int.random(in: 1...4096, using: &rng)), metadata: Self.meta("s\(i)"), quality: .original,
                                kind: kind, reason: kind == .download ? Self.reasons.randomElement(using: &rng) : nil,
                                fileExtension: "mp3", downloadsLimit: nil)
        }
        try await store.savePlaylist(DownloadedPlaylist(id: "p1", name: "P", coverArtId: nil, songIds: ["s0", "s1"], savedAt: Date()))
        let dir = store.directory
        let fm = FileManager.default
        let entries = await store.entries()
        var pristine = Set(entries.filter { $0.kind == .download }.map(\.fileName))
        var names = try fm.contentsOfDirectory(atPath: dir.path)
        names += (try? fm.contentsOfDirectory(atPath: dir.appending(path: "playlists").path).map { "playlists/" + $0 }) ?? []
        for name in names.sorted() where Int.random(in: 0..<3, using: &rng) == 0 {
            let url = dir.appending(path: name)
            let audioName = name.hasSuffix(".json") ? String(name.dropLast(5)) : name
            pristine.remove(audioName)
            switch Int.random(in: 0..<10, using: &rng) {
            case 0: try? fm.removeItem(at: url)
            case 1:   // a directory where a file should be
                try? fm.removeItem(at: url); try? fm.createDirectory(at: url, withIntermediateDirectories: true)
            case 2:   // a dangling symlink
                try? fm.removeItem(at: url); try? fm.createSymbolicLink(atPath: url.path, withDestinationPath: "/nonexistent/\(seed)")
            case 3:   // a symlink to a file outside the store
                let outside = tmp.appending(path: "outside-\(seed)-\(name.replacingOccurrences(of: "/", with: "_"))")
                try? Data("x".utf8).write(to: outside)
                try? fm.removeItem(at: url); try? fm.createSymbolicLink(at: url, withDestinationURL: outside)
            default:
                if let data = try? Data(contentsOf: url) { try? Self.mangle(data, &rng).write(to: url) }
            }
        }
        // Kill mid-write: AtomicFile temp files, some for the index.
        for _ in 0..<Int.random(in: 0...2, using: &rng) {
            let target = Bool.random(using: &rng) ? "index.json" : (entries.randomElement(using: &rng)?.fileName ?? "x") + ".json"
            try? Data("{".utf8).write(to: dir.appending(path: ".\(target).\(UUID().uuidString).tmp"))
        }
        return (dir, pristine, rng)
    }

    /// Every invariant a store must keep whatever was on disk.
    func checkInvariants(_ store: AudioStore, seed: UInt64) async {
        let entries = await store.entries()
        for e in entries where e.kind == .download {
            #expect(!e.reasons.isEmpty, "seed \(seed): download \(e.songId) has no reason, so nothing but Remove all can remove it")
        }
        _ = await store.usage()   // must not trap, whatever sizes the files claim
        _ = await store.localFiles()
        _ = await store.playlists()
        _ = OfflineCatalog(entries: entries, playlists: await store.playlists()).albums()
    }

    @Test func damagedFilesNeverTrapNorLoseDownloads() async throws {
        var cases = 0
        for seed in UInt64(1)...60 {
            let (dir, pristine, rngIn) = try await damagedStore(seed: seed, count: 6)
            var rng = rngIn
            let faults = FaultyReader()
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            for name in names where Int.random(in: 0..<5, using: &rng) == 0 {
                faults.failing.withLock { $0[name] = [EPERM, EIO, ENOSPC, EACCES].randomElement(using: &rng)! }
            }
            let available = Bool.random(using: &rng)
            let root = dir.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let store = AudioStore(root: root, scope: "s", isProtectedDataAvailable: { available }, retryInterval: 0,
                                   read: faults.reader())
            await store.load()
            await checkInvariants(store, seed: seed)
            // Store operations that are not a user removal.
            _ = try? await store.evictCache(limit: Int64.random(in: 0...5000, using: &rng), protecting: [])
            _ = try? await store.promote(songId: "s\(Int.random(in: 0..<8, using: &rng))", reason: .song,
                                         downloadsLimit: [0, 1, nil, .max].randomElement(using: &rng)!)
            _ = try? await store.add(temp(10), metadata: Self.meta("new\(seed)"), quality: .original, kind: .download,
                                     reason: .song, fileExtension: "mp3", downloadsLimit: [0, .max, nil].randomElement(using: &rng)!)
            try? await store.markPlayed(songId: "s1")
            _ = try? await store.removeCache(songIds: ["s0", "s1", "s2"])
            await checkInvariants(store, seed: seed)

            // Every file now reads: a fresh load must still find each pristine download on disk.
            faults.enabled.withLock { $0 = false }
            await store.load()
            await checkInvariants(store, seed: seed)
            for name in pristine {
                #expect(FileManager.default.fileExists(atPath: dir.appending(path: name).path),
                        "seed \(seed): pristine download \(name) deleted without a removal")
            }
            cases += 1
        }
        #expect(cases == 60)
    }

    /// A download record with an empty reason list (or a cache record whose kind was damaged to download) would be
    /// kept with nothing that could remove it on its own: it decodes with `.unknown`.
    @Test func downloadWithNoReasonDecodesAsUnknown() async throws {
        let (root, store) = try await hugeStore("noreason")
        for e in await store.entries() {
            let sidecar = store.directory.appending(path: e.fileName + ".json")
            var obj = try JSONSerialization.jsonObject(with: Data(contentsOf: sidecar)) as! [String: Any]
            obj["kind"] = "download"; obj["reasons"] = []
            try JSONSerialization.data(withJSONObject: obj).write(to: sidecar)
        }
        try FileManager.default.removeItem(at: store.directory.appending(path: "index.json"))
        let again = AudioStore(root: root, scope: "s")
        await again.load()
        #expect(await again.entries().count == 3)
        #expect(await again.entries().allSatisfy { $0.reasons == [.unknown] })
        #expect(try await again.removeReason(.unknown).count == 3)
    }

    func hugeStore(_ name: String) async throws -> (URL, AudioStore) {
        let root = tmp.appending(path: name)
        let store = AudioStore(root: root, scope: "s")
        await store.load()
        for i in 0..<3 {
            try await store.add(temp(10), metadata: Self.meta("h\(i)"), quality: .original, kind: i == 2 ? .cache : .download,
                                reason: i == 2 ? nil : .song, fileExtension: "mp3", downloadsLimit: nil)
        }
        for e in await store.entries() {
            let sidecar = store.directory.appending(path: e.fileName + ".json")
            var obj = try JSONSerialization.jsonObject(with: Data(contentsOf: sidecar)) as! [String: Any]
            obj["size"] = NSNumber(value: Int64.max)
            try JSONSerialization.data(withJSONObject: obj).write(to: sidecar)
        }
        return (root, store)
    }

    /// Before first unlock the store serves the index as it reads, unchecked: huge sizes there must not trap the
    /// Settings usage line.
    @Test func hugeIndexSizesBeforeFirstUnlockDoNotOverflow() async throws {
        let (root, store) = try await hugeStore("huge-locked")
        let index = store.directory.appending(path: "index.json")
        var obj = try JSONSerialization.jsonObject(with: Data(contentsOf: index)) as! [String: Any]
        var entries = obj["entries"] as! [String: Any]
        for (k, v) in entries { var e = v as! [String: Any]; e["size"] = NSNumber(value: Int64.max); entries[k] = e }
        obj["entries"] = entries
        try JSONSerialization.data(withJSONObject: obj).write(to: index)
        let locked = AudioStore(root: root, scope: "s", isProtectedDataAvailable: { false }, read: { url in
            if url.lastPathComponent != "index.json" { throw CocoaError(.fileReadNoPermission) }
            return try Data(contentsOf: url)
        })
        await locked.load()
        #expect(await locked.isReady() == false)
        let usage = await locked.usage()
        #expect(usage.downloadBytes >= 0 && usage.cacheBytes >= 0)
    }

    /// The sidecars claim sizes that overflow when summed, and the audio can't be sized (a directory where the file
    /// should be): usage and the quota check must not trap.
    @Test func hugeClaimedSizesDoNotOverflow() async throws {
        let (root, store) = try await hugeStore("huge")
        for e in await store.entries() {
            let audio = store.directory.appending(path: e.fileName)
            try FileManager.default.removeItem(at: audio)
            try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: false)
        }
        try FileManager.default.removeItem(at: store.directory.appending(path: "index.json"))
        let again = AudioStore(root: root, scope: "s")
        await again.load()
        let usage = await again.usage()
        #expect(usage.downloadBytes >= 0 && usage.cacheBytes >= 0)
        // A store whose sizes can't be trusted refuses a limited download rather than trapping.
        await #expect(throws: AudioStoreError.downloadsFull) {
            try await again.add(self.temp(10), metadata: Self.meta("n"), quality: .original, kind: .download,
                                reason: .song, fileExtension: "mp3", downloadsLimit: DownloadsLimit.gb50.bytes)
        }
        _ = try await again.evictCache(limit: 0, protecting: [])
    }

    /// A store the app can't write to (read-only directory: the writes fail like a full or broken disk).
    @Test func writeFailuresNeverTrapNorLoseDownloads() async throws {
        for seed in UInt64(100)..<130 {
            var rng = SeededRNG(seed: seed)
            let root = tmp.appending(path: "ro-\(seed)")
            let store = AudioStore(root: root, scope: "s")
            await store.load()
            for i in 0..<4 {
                try await store.add(temp(100), metadata: Self.meta("s\(i)"), quality: .original, kind: i % 2 == 0 ? .download : .cache,
                                    reason: i % 2 == 0 ? .song : nil, fileExtension: "mp3", downloadsLimit: nil)
            }
            let downloads = Set(await store.entries().filter { $0.kind == .download }.map(\.fileName))
            chmod(store.directory.path, 0o555)
            defer { chmod(store.directory.path, 0o755) }
            for _ in 0..<12 {
                switch Int.random(in: 0..<7, using: &rng) {
                case 0: _ = try? await store.add(temp(50), metadata: Self.meta("n\(Int.random(in: 0..<3, using: &rng))"),
                                                 quality: .original, kind: Bool.random(using: &rng) ? .download : .cache,
                                                 reason: .song, fileExtension: "mp3", downloadsLimit: nil)
                case 1: _ = try? await store.promote(songId: "s1", reason: .favourites, downloadsLimit: nil)
                case 2: _ = try? await store.evictCache(limit: 0, protecting: [])
                case 3: try? await store.markPlayed(songId: "s\(Int.random(in: 0..<4, using: &rng))")
                case 4: _ = try? await store.replace(songId: "s0", with: temp(70), quality: .aacMedium, fileExtension: "aac")
                case 5: try? await store.savePlaylist(DownloadedPlaylist(id: "p", name: "P", coverArtId: nil, songIds: [], savedAt: Date()))
                default: await store.load()
                }
            }
            chmod(store.directory.path, 0o755)
            let fresh = AudioStore(root: root, scope: "s")
            await fresh.load()
            await checkInvariants(fresh, seed: seed)
            let kept = Set(await fresh.entries().filter { $0.kind == .download }.map(\.songId))
            #expect(kept.isSuperset(of: ["s0", "s2"]), "seed \(seed): \(kept) lost a download (files \(downloads))")
        }
    }

    /// The scope's directory is a file, or a symlink to nowhere: no trap, writes refused, the user's erase still works.
    @Test func directoryReplacedByFileOrSymlink() async throws {
        for variant in 0..<3 {
            let root = tmp.appending(path: "dirfile-\(variant)")
            let probe = AudioStore(root: root, scope: "s")
            try FileManager.default.createDirectory(at: probe.directory.deletingLastPathComponent(), withIntermediateDirectories: true)
            switch variant {
            case 0: try Data("not a dir".utf8).write(to: probe.directory)
            case 1: try FileManager.default.createSymbolicLink(atPath: probe.directory.path, withDestinationPath: "/nonexistent/x")
            default:
                let elsewhere = tmp.appending(path: "elsewhere-\(variant)")
                try Data().write(to: elsewhere)
                try FileManager.default.createSymbolicLink(at: probe.directory, withDestinationURL: elsewhere)
            }
            let store = AudioStore(root: root, scope: "s", retryInterval: 0, read: { try Data(contentsOf: $0) })
            await store.load()
            _ = await store.usage(); _ = await store.entries()
            _ = try? await store.add(temp(10), metadata: Self.meta("a"), quality: .original, kind: .download, reason: .song,
                                     fileExtension: "mp3", downloadsLimit: nil)
            _ = try? await store.evictCache(limit: 0, protecting: [])
            try? await store.saveCover(Data([1]), coverArtId: "c")
            await store.eraseScope()
            #expect(await store.isReady())
        }
    }

    /// Many adds, promotes, removals, evictions, remove-alls and sign-outs at once: the actor must come out
    /// consistent (index agrees with disk) and never trap.
    @Test func concurrencyStorm() async throws {
        for seed in UInt64(200)..<215 {
            let root = tmp.appending(path: "storm-\(seed)")
            let store = AudioStore(root: root, scope: "s")
            await store.load()
            let files = (0..<120).map { _ in temp(64) }
            await withTaskGroup(of: Void.self) { group in
                var rng = SeededRNG(seed: seed)
                for i in 0..<120 {
                    let op = Int.random(in: 0..<10, using: &rng), id = "s\(Int.random(in: 0..<15, using: &rng))"
                    let reason = Self.reasons.randomElement(using: &rng)!, file = files[i]
                    let limit: Int64? = [nil, 0, 500, .max].randomElement(using: &rng)!
                    group.addTask {
                        switch op {
                        case 0, 1, 2: _ = try? await store.add(file, metadata: Self.meta(id), quality: .original,
                                                               kind: op == 0 ? .cache : .download, reason: reason,
                                                               fileExtension: "mp3", downloadsLimit: limit)
                        case 3: _ = try? await store.promote(songId: id, reason: reason, downloadsLimit: limit)
                        case 4: _ = try? await store.removeReason(reason, songIds: [id])
                        case 5: _ = try? await store.evictCache(limit: 100, protecting: { [id] })
                        case 6: _ = try? await store.removeCache(songIds: [id], sparing: { [] })
                        case 7: if i % 40 == 7 { await store.eraseScope() } else { try? await store.markPlayed(songId: id) }
                        case 8: if i % 30 == 8 { try? await store.removeAll(kind: .download) } else { _ = try? await store.replace(songId: id, with: file, quality: .aacMedium, fileExtension: "aac") }
                        default: await store.load()
                        }
                    }
                }
            }
            let before = await store.entries()
            await checkInvariants(store, seed: seed)
            let limited = before.filter { $0.kind == .download }.reduce(Int64(0)) { $0 + $1.size }
            #expect(limited >= 0)
            let reloaded = AudioStore(root: root, scope: "s")
            await reloaded.load()
            #expect(Set(await reloaded.entries().map(\.songId)) == Set(before.map(\.songId)), "seed \(seed)")
        }
    }

    /// Quota edges: a 0 limit refuses every download; `Int64.max` takes them; the downloads never exceed a limit.
    @Test func quotaEdges() async throws {
        var rng = SeededRNG(seed: 7)
        for limit in [Int64(0), 1, 999, 5000, .max - 1, .max] {
            let root = tmp.appending(path: "quota-\(limit)")
            let store = AudioStore(root: root, scope: "s")
            await store.load()
            for i in 0..<30 {
                let size = Int.random(in: 1...800, using: &rng)
                let kind: AudioKind = Bool.random(using: &rng) ? .cache : .download
                _ = try? await store.add(temp(size), metadata: Self.meta("q\(i % 20)"), quality: .original, kind: kind,
                                         reason: .song, fileExtension: "mp3", downloadsLimit: limit)
                _ = try? await store.promote(songId: "q\(Int.random(in: 0..<20, using: &rng))", reason: .album("a"),
                                             downloadsLimit: limit)
                #expect(await store.usage().downloadBytes <= limit, "limit \(limit)")
            }
            if limit == 0 { #expect(await store.usage().downloadBytes == 0) }
        }
    }

    /// "Re-download in this format" swaps in a file of another size: a bigger one that would take the downloads past
    /// their limit is refused, and the old file stays. A cached song's re-download isn't held to the downloads limit.
    @Test func redownloadRespectsTheLimit() async throws {
        let store = AudioStore(root: tmp.appending(path: "redl"), scope: "s")
        await store.load()
        try await store.add(temp(800), metadata: Self.meta("d"), quality: .original, kind: .download, reason: .song,
                            fileExtension: "mp3", downloadsLimit: 1000)
        try await store.add(temp(500), metadata: Self.meta("c"), quality: .original, kind: .cache, reason: nil,
                            fileExtension: "mp3", downloadsLimit: nil)
        await #expect(throws: AudioStoreError.downloadsFull) {
            try await store.replace(songId: "d", with: self.temp(1500), quality: .aacMedium, fileExtension: "aac",
                                    downloadsLimit: 1000)
        }
        let kept = try #require(await store.entry(songId: "d"))
        #expect(kept.quality == .original && kept.size == 800)
        #expect(FileManager.default.fileExists(atPath: store.directory.appending(path: kept.fileName).path))
        #expect(await store.usage().downloadBytes == 800)
        // Smaller fits; the cached song isn't counted against the downloads limit.
        try await store.replace(songId: "d", with: temp(900), quality: .aacMedium, fileExtension: "aac", downloadsLimit: 1000)
        try await store.replace(songId: "c", with: temp(5000), quality: .aacMedium, fileExtension: "aac", downloadsLimit: 1000)
        #expect(await store.usage() == AudioUsage(downloadBytes: 900, cacheBytes: 5000))
    }

    // MARK: - Scrobble queue

    /// Corrupt, truncated, empty and huge queue files and failing reads: never a trap; an unread file is never
    /// written over or removed by anything but `clear()`.
    @Test func scrobbleQueueFileFuzz() async throws {
        let base = Data(try JSONEncoder().encode((0..<5).map { i in
            QueuedScrobble(destination: i % 2 == 0 ? .navidrome : .listenBrainz,
                           song: Self.meta("q\(i)"), listenedAt: Date(timeIntervalSince1970: Double(i)))
        }))
        for seed in UInt64(300)..<380 {
            var rng = SeededRNG(seed: seed)
            let url = tmp.appending(path: "sq-\(seed)/scrobble-queue.json")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            var contents = Self.mangle(base, &rng)
            if seed % 10 == 0 {   // huge: well past the limit, every entry must be kept bounded
                contents = try JSONEncoder().encode((0..<1500).map { i in
                    QueuedScrobble(destination: .navidrome, song: Self.meta("h\(i)"), listenedAt: Date(timeIntervalSince1970: Double(i)))
                })
            }
            try contents.write(to: url)
            let failsFor = Int.random(in: 0...3, using: &rng)   // the first reads fail (locked phone, EIO)
            let failure = [EPERM, EIO].randomElement(using: &rng)!
            let reads = Mutex(0)
            let reader: ScrobbleQueue.Reader = { u in
                let n = reads.withLock { $0 += 1; return $0 }
                if n <= failsFor { throw NSError(domain: NSPOSIXErrorDomain, code: Int(failure)) }
                return try ScrobbleQueue.fileReader(u)
            }
            let q = ScrobbleQueue(fileURL: url, reader: reader)
            for i in 0..<Int.random(in: 0...4, using: &rng) {
                await q.enqueue(QueuedScrobble(destination: .listenBrainz, song: Self.meta("n\(i)"), listenedAt: Date()))
                if reads.withLock({ $0 }) <= failsFor {
                    #expect(try Data(contentsOf: url) == contents, "seed \(seed): written before it was read")
                }
            }
            await q.reload()
            _ = await q.pending(.navidrome)
            #expect(await q.pending(.navidrome).count <= ScrobbleQueue.limit)
            #expect(await q.pending(.listenBrainz).count <= ScrobbleQueue.limit)
            if let ids = await q.pending(.listenBrainz).first.map({ [$0.id] }) { await q.remove(ids: Set(ids)) }
        }
    }

    // MARK: - Offline catalog and pre-download plan

    @Test func offlineCatalogFuzz() {
        var rng = SeededRNG(seed: 400)
        let words = ["", " ", "A", "a", "É", "e\u{301}", "🎵", "\u{0}", String(repeating: "z", count: 300), "Ab", "ab"]
        for _ in 0..<300 {
            let entries: [AudioEntry] = (0..<Int.random(in: 0..<25, using: &rng)).map { i in
                var m = AudioMetadata(Song(id: "s\(Int.random(in: 0..<20, using: &rng))", title: words.randomElement(using: &rng)!,
                                           artist: words.randomElement(using: &rng)!, artistId: Bool.random(using: &rng) ? nil : words.randomElement(using: &rng),
                                           album: words.randomElement(using: &rng)!, albumId: Bool.random(using: &rng) ? nil : words.randomElement(using: &rng),
                                           track: [nil, .min, -1, 0, 1, .max].randomElement(using: &rng)!,
                                           disc: [nil, .min, 0, 1, .max].randomElement(using: &rng)!,
                                           duration: [0, -1, .nan, .infinity, -.infinity, 1e300, 200].randomElement(using: &rng)!,
                                           genre: words.randomElement(using: &rng)))
                m.albumCoverArtId = Bool.random(using: &rng) ? "c\(i)" : nil
                return AudioEntry(songId: m.songId, quality: .original, fileName: "f\(i)", size: Int64.random(in: .min ... .max, using: &rng),
                                  kind: Bool.random(using: &rng) ? .download : .cache, reasons: [.song],
                                  downloadedAt: Date(timeIntervalSince1970: Double.random(in: 0...1e9, using: &rng)),
                                  lastPlayed: Bool.random(using: &rng) ? nil : Date(timeIntervalSince1970: Double.random(in: 0...1e9, using: &rng)),
                                  metadata: m)
            }
            let playlists = (0..<Int.random(in: 0..<4, using: &rng)).map { p in
                DownloadedPlaylist(id: "p\(p % 2)", name: words.randomElement(using: &rng)!, coverArtId: nil,
                                   songIds: (0..<Int.random(in: 0..<10, using: &rng)).map { _ in "s\(Int.random(in: 0..<25, using: &rng))" },
                                   savedAt: Date())
            }
            let catalog = OfflineCatalog(entries: entries, playlists: playlists)
            for album in catalog.albums() { _ = catalog.album(id: album.id) }
            for artist in catalog.artists() { _ = catalog.albums(byArtist: artist.id) }
            for playlist in catalog.playlists() { _ = catalog.songs(inPlaylist: playlist.id) }
            _ = catalog.songs(); _ = catalog.genres()
            _ = catalog.search(words.randomElement(using: &rng)!)
            _ = catalog.recentlyPlayed(matching: words.randomElement(using: &rng)!)
        }
    }

    @Test func preDownloadPlanFuzz() {
        var rng = SeededRNG(seed: 500)
        for _ in 0..<1000 {
            let upcoming = (0..<Int.random(in: 0..<30, using: &rng)).map {
                Song(id: "s\(Int.random(in: 0..<12, using: &rng))", title: "\($0)", artist: "", album: "", duration: 1)
            }
            let local = Set((0..<Int.random(in: 0..<12, using: &rng)).map { "s\($0)" })
            let count = [Int.min, -1, 0, 1, 3, 10, Int.max].randomElement(using: &rng)!
            let plan = PreDownloadPlan.songs(upcoming: upcoming, count: count, isLocal: { local.contains($0) })
            #expect(plan.count <= max(0, count))
            #expect(Set(plan.map(\.id)).count == plan.count)
            #expect(plan.allSatisfy { !local.contains($0.id) })
        }
    }
}
