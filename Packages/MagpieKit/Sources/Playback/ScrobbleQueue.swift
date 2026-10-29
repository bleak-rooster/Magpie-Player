import Foundation
import MagpieCore

/// Where a play is sent (spec §7): through Navidrome (which may forward it), or straight to ListenBrainz.
public enum ScrobbleDestination: String, Codable, Sendable { case navidrome, listenBrainz }

/// A play that couldn't be sent (offline, or the send failed), waiting to go again. Metadata only: the song's own
/// fields and when it was listened to, never a credential or a URL.
public struct QueuedScrobble: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var destination: ScrobbleDestination
    public var song: AudioMetadata
    public var listenedAt: Date
    /// The song's library (native API songs), kept so the dequeue check (D29) judges the play as the send did.
    public var libraryId: Int?

    public init(id: UUID = UUID(), destination: ScrobbleDestination, song: AudioMetadata, listenedAt: Date,
                libraryId: Int? = nil) {
        self.id = id; self.destination = destination; self.song = song; self.listenedAt = listenedAt
        self.libraryId = libraryId
    }

    public init(id: UUID = UUID(), destination: ScrobbleDestination, song: Song, listenedAt: Date) {
        self.init(id: id, destination: destination, song: AudioMetadata(song), listenedAt: listenedAt,
                  libraryId: song.libraryId)
    }

    /// The song as played, library id included, for the find check.
    public var playedSong: Song {
        var s = song.song
        s.libraryId = libraryId
        return s
    }
}

/// The persisted queue of unsent plays (spec §7), one list per destination, oldest first. Each list keeps at most
/// `limit` entries: past that the oldest goes. The file (`scrobble-queue.json`) is written atomically, excluded from
/// backup, and a corrupt one reads as empty. Nil `fileURL` keeps the queue in memory (tests).
///
/// A file that can't be read yet (protected before first unlock, any I/O error) is never written over: plays queued
/// meanwhile stay in memory, the read is tried again on each use and on `reload()`, and once it works they are
/// merged after what the file held.
public actor ScrobbleQueue {
    public static let limit = 500
    /// Reads the file: nil when there is none; throws when it can't be read.
    public typealias Reader = @Sendable (URL) throws -> Data?

    public static let fileReader: Reader = { url in
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    private let fileURL: URL?
    private let reader: Reader
    private var items: [QueuedScrobble]
    /// The file was read (or there is none). Until then nothing is saved.
    private var loaded: Bool

    public init(fileURL: URL?, reader: @escaping Reader = ScrobbleQueue.fileReader) {
        self.fileURL = fileURL
        self.reader = reader
        let read = fileURL.flatMap { Self.read($0, with: reader) }
        items = read ?? []
        loaded = fileURL == nil || read != nil
    }

    /// Application Support/Magpie/scrobble-queue.json under `directory`.
    public static func defaultURL(in directory: URL) -> URL {
        directory.appending(path: "Magpie/scrobble-queue.json")
    }

    /// Tries the file again if it couldn't be read yet (protected data became available).
    public func reload() {
        loadIfNeeded()
    }

    public func enqueue(_ s: QueuedScrobble) {
        enqueue(s) { true }
    }

    /// Queues `s` only if `stillWanted` holds when the queue takes it (checked on the actor, so a sign-out's
    /// `clear()` can't be overtaken by a play that started before it).
    public func enqueue(_ s: QueuedScrobble, when stillWanted: @Sendable () -> Bool) {
        loadIfNeeded()
        guard stillWanted() else { return }
        items.append(s)
        trim()
        save()
    }

    /// Oldest first.
    public func pending(_ d: ScrobbleDestination) -> [QueuedScrobble] {
        loadIfNeeded()
        return items.filter { $0.destination == d }
    }

    public func remove(ids: Set<UUID>) {
        loadIfNeeded()
        guard !ids.isEmpty else { return }
        let before = items.count
        items.removeAll { ids.contains($0.id) }
        if items.count != before { save() }
    }

    public func clear() {
        items = []
        guard let fileURL else { return }
        try? FileManager.default.removeItem(at: fileURL)
        loaded = true   // nothing left to read
    }

    // MARK: - File

    /// nil: unreadable. A file that reads but doesn't decode is corrupt and counts as empty.
    private static func read(_ url: URL, with reader: Reader) -> [QueuedScrobble]? {
        do {
            guard let data = try reader(url) else { return [] }
            return (try? JSONDecoder().decode([QueuedScrobble].self, from: data)) ?? []
        } catch {
            return nil
        }
    }

    private func loadIfNeeded() {
        guard !loaded, let fileURL, let read = Self.read(fileURL, with: reader) else { return }
        loaded = true
        let known = Set(read.map(\.id))
        let mergedSome = !items.isEmpty
        items = read + items.filter { !known.contains($0.id) }
        trim()
        if mergedSome { save() }
    }

    /// Past `limit` per destination, the oldest go.
    private func trim() {
        for destination in [ScrobbleDestination.navidrome, .listenBrainz] {
            let same = items.filter { $0.destination == destination }
            guard same.count > Self.limit else { continue }
            let dropped = Set(same.prefix(same.count - Self.limit).map(\.id))
            items.removeAll { dropped.contains($0.id) }
        }
    }

    private func save() {
        guard loaded, let fileURL else { return }
        do {
            try AtomicFile.write(items, to: fileURL)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var target = fileURL
            try target.setResourceValues(values)
        } catch {
            Log.logger("playback").error("scrobble queue not saved: \(error.localizedDescription, privacy: .private)")
        }
    }
}
