import Foundation
import MagpieCore

/// On-device JSON files for the Lidarr change log and the ledger: atomic writes, file protection
/// (via `AtomicFile`), kept out of device backups.
enum LocalFile {
    /// `Application Support/Magpie/<name>`.
    static func url(_ name: String, in directory: URL) -> URL {
        directory.appending(path: "Magpie/\(name)")
    }

    static func save<T: Encodable>(_ value: T, to url: URL) throws {
        try AtomicFile.write(value, to: url)
        // Set after every write: the atomic replace swaps in a new file.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var file = url
        try file.setResourceValues(values)
    }

    /// Reads the file, or `fallback` when there is none. A file that exists but cannot be decoded is moved
    /// aside (never overwritten: it is the owner's record of what Magpie changed) and `fallback` is returned.
    static func load<T: Decodable>(_ type: T.Type, from url: URL, fallback: T, category: String) -> T {
        do {
            return try AtomicFile.read(type, from: url) ?? fallback
        } catch {
            let aside = url.deletingLastPathComponent()
                .appending(path: "\(url.lastPathComponent).unreadable-\(Int(Date().timeIntervalSince1970))")
            try? FileManager.default.moveItem(at: url, to: aside)
            Log.logger(category).error("unreadable \(url.lastPathComponent, privacy: .public); kept aside, starting empty")
            return fallback
        }
    }
}
