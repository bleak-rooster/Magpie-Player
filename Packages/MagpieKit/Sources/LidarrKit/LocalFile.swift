import Foundation
import MagpieCore

enum LocalFileError: Error, Equatable {
    /// The file exists but cannot be read right now (e.g. protected data before first unlock). Callers must
    /// refuse to write rather than start over.
    case unavailable
}

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

    /// Reads the file, or `fallback` when there is none.
    /// - A file that cannot be *read* throws `LocalFileError.unavailable` and is left alone.
    /// - A file that reads but cannot be *decoded* is moved aside (never overwritten: it is the owner's record
    ///   of what Magpie changed) and `fallback` is returned.
    static func load<T: Decodable>(_ type: T.Type, from url: URL, fallback: T, category: String,
                                   read: (URL) throws -> Data = { try Data(contentsOf: $0) }) throws -> T {
        guard FileManager.default.fileExists(atPath: url.path) else { return fallback }
        let data: Data
        do { data = try read(url) } catch {
            Log.logger(category).error("cannot read \(url.lastPathComponent, privacy: .public) right now")
            throw LocalFileError.unavailable
        }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch is DecodingError {
            let aside = url.deletingLastPathComponent()
                .appending(path: "\(url.lastPathComponent).unreadable-\(Int(Date().timeIntervalSince1970))")
            // If it cannot be moved aside, refuse rather than let the next save overwrite it.
            do { try FileManager.default.moveItem(at: url, to: aside) } catch { throw LocalFileError.unavailable }
            Log.logger(category).error("damaged \(url.lastPathComponent, privacy: .public); kept aside, starting empty")
            return fallback
        } catch {
            throw LocalFileError.unavailable
        }
    }
}
