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
public actor ScrobbleQueue {
    public static let limit = 500

    private let fileURL: URL?
    private var items: [QueuedScrobble]

    public init(fileURL: URL?) {
        self.fileURL = fileURL
        items = fileURL.flatMap { try? AtomicFile.read([QueuedScrobble].self, from: $0) } ?? []
    }

    /// Application Support/Magpie/scrobble-queue.json under `directory`.
    public static func defaultURL(in directory: URL) -> URL {
        directory.appending(path: "Magpie/scrobble-queue.json")
    }

    public func enqueue(_ s: QueuedScrobble) {
        enqueue(s) { true }
    }

    /// Queues `s` only if `stillWanted` holds when the queue takes it (checked on the actor, so a sign-out's
    /// `clear()` can't be overtaken by a play that started before it).
    public func enqueue(_ s: QueuedScrobble, when stillWanted: @Sendable () -> Bool) {
        guard stillWanted() else { return }
        items.append(s)
        let same = items.filter { $0.destination == s.destination }
        if same.count > Self.limit {
            let dropped = Set(same.prefix(same.count - Self.limit).map(\.id))
            items.removeAll { dropped.contains($0.id) }
        }
        save()
    }

    /// Oldest first.
    public func pending(_ d: ScrobbleDestination) -> [QueuedScrobble] {
        items.filter { $0.destination == d }
    }

    public func remove(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let before = items.count
        items.removeAll { ids.contains($0.id) }
        if items.count != before { save() }
    }

    public func clear() {
        items = []
        guard let fileURL else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func save() {
        guard let fileURL else { return }
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
