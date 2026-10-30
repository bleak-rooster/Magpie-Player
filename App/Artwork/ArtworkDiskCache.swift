import CryptoKit
import Foundation
import MagpieCore
import Synchronization

/// Artwork kept on disk until the owner clears it (P4): `Application Support/Magpie/Artwork/<scope>/<name>`, where
/// the scope is the account's hex id and the name is `sha256(coverArtId|size)`. Never keyed by a URL (URLs carry
/// Subsonic auth). Files are excluded from backup and protected `completeUntilFirstUserAuthentication`, so the car
/// can read them while the phone is locked. No automatic eviction.
///
/// One actor, so a sign-out's erase and a late write are ordered: a write started before an erase (`generation`
/// older than the erase's) is refused, and so never lands in an erased scope.
actor ArtworkDiskCache {
    private static let instances = Mutex<[URL: ArtworkDiskCache]>([:])

    /// The one cache for `root` (the app's data directory; tests use their own), so erases and writes stay ordered.
    static func forRoot(_ root: URL) -> ArtworkDiskCache {
        instances.withLock { all in
            if let cache = all[root] { return cache }
            let cache = ArtworkDiskCache(root: root)
            all[root] = cache
            return cache
        }
    }

    /// Every size Magpie asks the server for (phone and car), so "Reload artwork" drops them all.
    static let sizes = [120, 300, 600, 1000]

    let root: URL
    /// Writes from before the latest erase are refused.
    private var minimumGeneration = 0

    init(root: URL) { self.root = root }

    var folder: URL { Self.folder(root: root) }

    nonisolated static func folder(root: URL) -> URL {
        root.appending(path: "Magpie", directoryHint: .isDirectory).appending(path: "Artwork", directoryHint: .isDirectory)
    }

    /// The file's name: a hash of the cover id and size, never a server string or URL.
    nonisolated static func fileName(coverArtId: String, size: Int) -> String {
        SHA256.hash(data: Data("\(coverArtId)|\(size)".utf8)).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func isScope(_ scope: String) -> Bool { scope.wholeMatch(of: /[A-Za-z0-9_-]{1,64}/) != nil }

    func url(scope: String, coverArtId: String, size: Int) -> URL? {
        guard Self.isScope(scope) else { return nil }
        return folder.appending(path: scope, directoryHint: .isDirectory)
            .appending(path: Self.fileName(coverArtId: coverArtId, size: size))
    }

    /// The cached image's bytes; nil when not cached (or not readable yet, before first unlock).
    func data(scope: String, coverArtId: String, size: Int) -> Data? {
        guard let url = url(scope: scope, coverArtId: coverArtId, size: size) else { return nil }
        return try? Data(contentsOf: url)
    }

    /// Saves an image. Refused when an erase has happened since `generation` was read.
    func save(_ data: Data, scope: String, coverArtId: String, size: Int, generation: Int) {
        guard generation >= minimumGeneration, !data.isEmpty,
              let url = url(scope: scope, coverArtId: coverArtId, size: size) else { return }
        let fm = FileManager.default
        let directory = url.deletingLastPathComponent()
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                                   attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var file = url, artwork = folder
            try file.setResourceValues(values)
            try artwork.setResourceValues(values)
        } catch {
            try? fm.removeItem(at: url)
            Log.logger("artwork").error("artwork not saved: \(Log.category(of: error), privacy: .public)")
        }
    }

    /// "Reload artwork": every cached size of one cover goes.
    func remove(scope: String, coverArtId: String) {
        for size in Self.sizes {
            if let url = url(scope: scope, coverArtId: coverArtId, size: size) { try? FileManager.default.removeItem(at: url) }
        }
    }

    /// The bytes on disk, every scope ("Artwork · 84 MB").
    func usage() -> Int64 {
        guard let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
        else { return 0 }
        var total: Int64 = 0
        for case let file as URL in files {
            guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    /// "Clear artwork cache": all of it goes. Covers saved with downloads live with the audio and stay.
    func clear() {
        try? FileManager.default.removeItem(at: folder)
    }

    /// Sign-out: the scope's artwork goes, and writes started before now are refused.
    func eraseScope(_ scope: String, generation: Int) {
        minimumGeneration = max(minimumGeneration, generation)
        guard Self.isScope(scope) else { return }
        try? FileManager.default.removeItem(at: folder.appending(path: scope, directoryHint: .isDirectory))
    }
}
