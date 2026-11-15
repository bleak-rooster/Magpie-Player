import Foundation
import MagpieCore

/// Round 28 O2 (owner, 2026-11-15, item 1: "anything that is downloaded should be cached"; amends D313 and resolves
/// round 27's parked "lyrics for offline"): the lyrics shown for a **downloaded** song, kept on the phone (D336).
///
/// One file per song, `Audio/<scope>/lyrics/<sha256(songId)>.json`, written by `AudioStore` (kept out of backups,
/// readable after first unlock), removed with the song and with the scope. D312's bounds: at most 2,000 lines of 500
/// characters, at most 512 KB a file; at most 20 MB in all (the oldest go first). Only the lines, whether they are
/// timed, where they came from and when: no URL, no query, no server string.
public struct OfflineLyrics: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public static let maxLines = LrcParser.maxLines
    public static let maxLineLength = LrcParser.maxLineLength
    public static let maxFileBytes = 512 * 1024
    public static let maxTotalBytes: Int64 = 20 * 1024 * 1024

    /// Where they came from: the library (the server), or found online (LRCLIB), as the pane's footer says (D313).
    public enum Source: String, Codable, Sendable { case library, online }

    public var version = OfflineLyrics.currentVersion
    public var songId: String
    public var source: Source
    /// The lines; nil for an instrumental (D311's note).
    public var lyrics: Lyrics?
    public var savedAt: Date

    public init(songId: String, source: Source, lyrics: Lyrics?, savedAt: Date) {
        self.songId = songId; self.source = source; self.savedAt = savedAt
        self.lyrics = lyrics.map(Self.bounded)
    }

    /// Whether they show the same as `other` (when they were saved doesn't count).
    public func showsSame(as other: OfflineLyrics) -> Bool {
        var a = self, b = other
        a.savedAt = .distantPast; b.savedAt = .distantPast
        return a == b
    }

    /// D312: at most `maxLines` lines of `maxLineLength` characters; a non-finite or negative time is dropped.
    static func bounded(_ lyrics: Lyrics) -> Lyrics {
        Lyrics(synced: lyrics.synced, lines: lyrics.lines.prefix(maxLines).map { line in
            LyricLine(start: line.start.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil },
                      text: line.text.count > maxLineLength ? String(line.text.prefix(maxLineLength)) : line.text)
        })
    }

    /// The saved file, or nil when it is too big, another version, for another song, or doesn't read.
    static func decode(_ data: Data, songId: String) -> OfflineLyrics? {
        guard data.count <= maxFileBytes, let kept = try? JSONDecoder().decode(OfflineLyrics.self, from: data),
              kept.version == currentVersion, kept.songId == songId else { return nil }
        if let lyrics = kept.lyrics, lyrics.lines.isEmpty { return nil }
        var bounded = kept
        bounded.lyrics = kept.lyrics.map(Self.bounded)
        return bounded
    }
}

// MARK: - The files (AudioStore)

/// Round 28 O2 (D336): the kept lyrics' files.
extension AudioStore {
    nonisolated var lyricsDirectory: URL { directory.appending(path: "lyrics", directoryHint: .isDirectory) }
    nonisolated func lyricsURL(songId: String) -> URL { lyricsDirectory.appending(path: Self.sha256(songId) + ".json") }

    /// Keeps `lyrics` for a downloaded song (never a cached one), when they show something different from what's kept.
    /// Lines that are all empty are none; a file over 512 KB once bounded is refused. Past 20 MB in all, the lyrics
    /// kept longest ago go (never these). Returns whether they were written.
    @discardableResult
    public func saveLyrics(_ lyrics: OfflineLyrics) throws -> Bool {
        try ensureReady()
        guard index.entries[lyrics.songId]?.kind == .download else { return false }
        if let lines = lyrics.lyrics, !lines.lines.contains(where: { !$0.text.isEmpty }) { return false }
        if let saved = savedLyrics(songId: lyrics.songId), saved.showsSame(as: lyrics) { return false }
        let data = try JSONEncoder().encode(lyrics)
        guard data.count <= OfflineLyrics.maxFileBytes else { return false }
        try prepareDirectory()
        try FileManager.default.createDirectory(at: lyricsDirectory, withIntermediateDirectories: true)
        try protect(lyricsDirectory)
        let url = lyricsURL(songId: lyrics.songId)
        try AtomicFile.write(lyrics, to: url)
        try protect(url)
        trimLyrics(sparing: url.lastPathComponent)
        return true
    }

    /// The lyrics kept for `songId`, or nil (none kept, damaged, or not readable yet).
    public func savedLyrics(songId: String) -> OfflineLyrics? {
        guard let data = try? reader(lyricsURL(songId: songId)) else { return nil }
        return OfflineLyrics.decode(data, songId: songId)
    }

    func setLyricsTotalLimitForTesting(_ bytes: Int64) { lyricsTotalLimit = bytes }

    /// Every kept file whose song isn't a download goes (and any file that isn't one of ours).
    func pruneLyrics(keeping songIds: Set<String>) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: lyricsDirectory.path)) ?? []
        guard !names.isEmpty else { return }
        let kept = Set(songIds.map { Self.sha256($0) + ".json" })
        for name in names where !kept.contains(name) {
            try? FileManager.default.removeItem(at: lyricsDirectory.appending(path: name))
        }
    }

    /// Past `lyricsTotalLimit`, the files saved longest ago go first (written once per save, so a file's date is when
    /// it was saved), never `sparing`.
    private func trimLyrics(sparing: String) {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        let names = (try? FileManager.default.contentsOfDirectory(atPath: lyricsDirectory.path)) ?? []
        var files: [(name: String, size: Int64, date: Date)] = names.compactMap { name in
            let values = try? lyricsDirectory.appending(path: name).resourceValues(forKeys: keys)
            return (name, Int64(values?.fileSize ?? 0), values?.contentModificationDate ?? .distantPast)
        }
        var total = files.reduce(Int64(0)) { Self.sum($0, $1.size) }
        guard total > lyricsTotalLimit else { return }
        files.sort { ($0.date, $0.name) < ($1.date, $1.name) }
        for file in files where total > lyricsTotalLimit && file.name != sparing {
            try? FileManager.default.removeItem(at: lyricsDirectory.appending(path: file.name))
            total -= min(total, file.size)
        }
    }
}
