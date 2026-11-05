import Foundation
import MagpieCore

/// Round 15 C3 (owner item 7, D137–D138): a find the owner let go (Not for me) leaves every one of the owner's own
/// playlists it was added to. The clean-up is saved before anything is removed, done just before the find's files are
/// deleted (Navidrome's scan after the delete would otherwise leave entries for songs that are gone), and tried again
/// after an interruption until every playlist is clean. Finished ones stay as a short history (Finds › Recently let go).
public struct FindCleanup: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var requestId: RequestID
    /// The song's (or album's) name, for the message.
    public var title: String
    /// The find's songs in the library (its whole release goes).
    public var songIds: [String]
    public var createdAt: Date
    /// The owner's playlists entries were removed from so far (names, in order).
    public var playlists: [String]
    /// Every playlist checked clean (or nothing could be removed): the message was given.
    public var finishedAt: Date?
    /// A playlist whose listing didn't match its count (entries the server hides): left alone, and said so.
    public var skipped: [String]?

    public init(id: UUID = UUID(), requestId: RequestID, title: String, songIds: [String], createdAt: Date) {
        self.id = id; self.requestId = requestId; self.title = title; self.songIds = songIds; self.createdAt = createdAt
        self.playlists = []
    }
}

public enum FindCleanups {
    /// Finished clean-ups kept as history.
    public static let historyLimit = 20
    /// Playlists named in the message before "and N more".
    static let namedLimit = 3

    /// Every position holding one of `songIds` (duplicates too), highest first: removed from the highest index down, so
    /// each index still means the same entry however the server applies them. Other entries are untouched.
    public static func indexesToRemove(_ songIds: Set<String>, in list: [String]) -> [Int] {
        list.indices.filter { songIds.contains(list[$0]) }.sorted(by: >)
    }

    /// "Removed “Song” from 2 playlists: Road Trip, Chill"; nil when it was in none.
    public static func message(title: String, playlists: [String]) -> String? {
        guard let first = playlists.first else { return nil }
        let name = "\u{201C}\(title)\u{201D}"
        guard playlists.count > 1 else { return "Removed \(name) from \(first)" }
        let named = playlists.prefix(namedLimit).joined(separator: ", ")
        let rest = playlists.count - namedLimit
        return "Removed \(name) from \(playlists.count) playlists: " + (rest > 0 ? "\(named) and \(rest) more" : named)
    }

    /// Unfinished ones always stay; of the finished, the latest `historyLimit`.
    public static func trimmed(_ jobs: [FindCleanup]) -> [FindCleanup] {
        let open = jobs.filter { $0.finishedAt == nil }
        let done = jobs.filter { $0.finishedAt != nil }.sorted { $0.finishedAt! > $1.finishedAt! }.prefix(historyLimit)
        return open + done
    }
}

/// `Application Support/Magpie/find-cleanups-<instance>.json`, one per Lidarr like the requests (atomic, excluded from
/// backup, lenient, erased with the requests on sign-out: `RequestStore.eraseAll`).
public actor FindCleanupStore {
    public static func defaultURL(in directory: URL = URL.applicationSupportDirectory, instance: String) -> URL {
        directory.appending(path: "Magpie/find-cleanups-\(instance).json")
    }

    nonisolated let fileURL: URL?
    private var memory: [FindCleanup] = []

    public init(fileURL: URL?) { self.fileURL = fileURL }

    public func load() throws -> [FindCleanup] {
        guard let fileURL else { return memory }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data: Data
        do { data = try Data(contentsOf: fileURL) } catch { throw RequestStoreError.unavailable }
        guard let rows = try? JSONDecoder().decode([Lenient].self, from: data) else {
            let aside = fileURL.deletingLastPathComponent()
                .appending(path: "\(fileURL.lastPathComponent).unreadable-\(Int(Date().timeIntervalSince1970))")
            try? FileManager.default.moveItem(at: fileURL, to: aside)
            return []
        }
        return rows.compactMap(\.value)
    }

    public func save(_ jobs: [FindCleanup]) throws {
        let jobs = FindCleanups.trimmed(jobs)
        guard let fileURL else { memory = jobs; return }
        try AtomicFile.write(jobs, to: fileURL)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var file = fileURL
        try? file.setResourceValues(values)
    }

    private struct Lenient: Decodable {
        let value: FindCleanup?
        init(from decoder: Decoder) throws { value = try? FindCleanup(from: decoder) }
    }
}
