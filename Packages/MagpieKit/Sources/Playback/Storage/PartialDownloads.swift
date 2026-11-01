import CryptoKit
import Foundation
import MagpieCore

/// What a download stopped part-way leaves behind (R1), in the store's `partials` folder, per job key
/// (`sha256(songId|quality)`, never a server string):
/// - `<key>.resume`: URLSession's resume data, kept from a cancellation or an error;
/// - `<key>.part`: bytes Magpie holds itself, for the HTTP Range fallback;
/// - `<key>.json`: `Info` (bytes so far, the size expected, and what the server said about ranges).
///
/// Resume data holds the request, whose URL carries the Subsonic token like every stream URL (accepted in
/// decisions.md, R1): the folder is kept out of backups, readable after first unlock only, removed when the download is
/// cancelled and on sign-out. Partials count toward the downloads limit (`AudioStore.checkLimit`).
public struct PartialDownloads: Sendable {
    public struct Info: Codable, Equatable, Sendable {
        public var received: Int64
        public var expected: Int64?
        /// Original (`format=raw`) streams can be byte-resumed; a transcoded one always restarts from zero.
        public var isOriginal: Bool
        /// What the request allowed when it started: resume data replays that request as it was.
        public var allowsCellular: Bool
        /// ETag, else Last-Modified: sent as `If-Range`, so a file changed on the server comes back whole.
        public var validator: String?
        public var acceptsRanges: Bool
        public var mimeType: String?

        public init(received: Int64, expected: Int64?, isOriginal: Bool, allowsCellular: Bool, validator: String?,
                    acceptsRanges: Bool, mimeType: String?) {
            self.received = received; self.expected = expected; self.isOriginal = isOriginal
            self.allowsCellular = allowsCellular; self.validator = validator; self.acceptsRanges = acceptsRanges
            self.mimeType = mimeType
        }
    }

    /// Bytes so far and expected, for "Paused · 2.1 of 8.4 MB".
    public struct Progress: Equatable, Sendable {
        public var received: Int64
        public var expected: Int64?
        public init(received: Int64, expected: Int64?) { self.received = received; self.expected = expected }
    }

    public struct RangeRequest: Equatable, Sendable {
        /// `bytes=<partial size>-`.
        public var range: String
        public var ifRange: String
    }

    /// The parts of `Content-Range: bytes <start>-<end>/<total>`.
    public struct ContentRange: Equatable, Sendable {
        public var start: Int64
        public var end: Int64
        public var total: Int64?
    }

    public enum RangeOutcome: Equatable, Sendable {
        /// The whole file, verified against the size the server gave: the caller owns it now.
        case complete(URL)
        /// More arrived but not all of it: kept, and the next Range asks for the rest.
        case incomplete
        /// What came back doesn't fit the partial (another start, a short whole file): dropped, start from zero.
        case restart
    }

    public enum RangeError: Error, Equatable { case status(Int) }

    static let extensions = ["resume", "part", "json", "landing", "done"]

    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    // MARK: - Names

    public static func key(songId: String, quality: StreamQuality) -> String {
        SHA256.hash(data: Data("\(songId)|\(quality.rawValue)".utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public static func isKey(_ text: String) -> Bool { text.wholeMatch(of: /[0-9a-f]{64}/) != nil }

    public func url(_ key: String, _ ext: String) -> URL {
        precondition(Self.isKey(key) && Self.extensions.contains(ext), "partials are named by key only")
        return directory.appending(path: "\(key).\(ext)")
    }

    // MARK: - Reading

    public func info(_ key: String) -> Info? {
        guard let data = try? Data(contentsOf: url(key, "json")) else { return nil }
        return try? JSONDecoder().decode(Info.self, from: data)
    }

    public func resumeData(_ key: String) -> Data? { try? Data(contentsOf: url(key, "resume")) }

    /// Bytes held for the Range fallback (0 when none).
    public func partSize(_ key: String) -> Int64 { Self.size(of: url(key, "part")) }

    /// What a resumable partial shows while paused; nil for a transcoded one (it restarts) or with nothing received.
    public func progress(_ key: String) -> Progress? {
        guard let info = info(key), info.isOriginal, info.received > 0 else { return nil }
        // Review M4: only when something is kept to resume from (resume data or bytes); counts alone restart.
        let fm = FileManager.default
        guard fm.fileExists(atPath: url(key, "resume").path) || partSize(key) > 0 else { return nil }
        return Progress(received: info.received, expected: info.expected)
    }

    /// Every key with something in the folder.
    public func keys() -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return Set(names.compactMap(Self.keyOf))
    }

    public func totalBytes() -> Int64 {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { Self.keyOf($0) != nil }
            .reduce(Int64(0)) { AudioStore.sum($0, Self.size(of: directory.appending(path: $1))) }
    }

    // MARK: - Writing

    public func saveInfo(_ info: Info, key: String) throws {
        try prepare()
        let file = url(key, "json")
        try AtomicFile.write(info, to: file)
        try Self.protect(file)
    }

    public func saveResumeData(_ data: Data, key: String) throws {
        try prepare()
        let file = url(key, "resume")
        try data.write(to: file, options: .atomic)
        try Self.protect(file)
    }

    /// Moves `file` in as `<key>.<ext>` (replacing what was there), protected like the rest.
    @discardableResult
    public func adopt(_ file: URL, key: String, as ext: String) throws -> URL {
        try prepare()
        let destination = url(key, ext)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: file, to: destination)
        try Self.protect(destination)
        return destination
    }

    /// Keeps `file` as the bytes held for `key`, with what the server said about them.
    public func adoptPart(_ file: URL, info: Info, key: String) throws {
        try adopt(file, key: key, as: "part")
        var info = info
        info.received = partSize(key)
        try saveInfo(info, key: key)
    }

    public func remove(_ key: String) {
        for ext in Self.extensions { try? FileManager.default.removeItem(at: url(key, ext)) }
    }

    /// Removes every key but `keys`; returns the ones removed. Files Magpie didn't name are left alone.
    @discardableResult
    public func retain(only keys: Set<String>) -> Set<String> {
        let gone = self.keys().subtracting(keys)
        for key in gone { remove(key) }
        return gone
    }

    /// Cancel all, sign-out.
    public func removeAll() { try? FileManager.default.removeItem(at: directory) }

    // MARK: - Range fallback

    /// The Range request that continues the bytes held for `key`, or nil when it can't: nothing held, a transcoded
    /// stream (a new conversion needn't give the same bytes), or a server that sent no validator or no byte ranges.
    public func rangeRequest(_ key: String) -> RangeRequest? {
        let size = partSize(key)
        guard size > 0, let info = info(key), info.isOriginal, info.acceptsRanges,
              let validator = info.validator, !validator.isEmpty else { return nil }
        return RangeRequest(range: "bytes=\(size)-", ifRange: validator)
    }

    /// Applies the answer to `rangeRequest(key)`; `body` is consumed. A 206 must start where the partial ends, and is
    /// appended; the result must reach the total `Content-Range` gave. A 200 (If-Range failed: the file changed) is the
    /// whole file, checked against `expected` (its Content-Length). Anything else throws its status.
    public func appendRange(_ body: URL, status: Int, contentRange: String?, key: String,
                            expected: Int64? = nil) throws -> RangeOutcome {
        defer { try? FileManager.default.removeItem(at: body) }
        switch status {
        case 206:
            let part = url(key, "part")
            guard let range = contentRange.flatMap(Self.parseContentRange), range.start == partSize(key),
                  let info = info(key) else {
                remove(key)
                return .restart
            }
            let handle = try FileHandle(forWritingTo: part)
            defer { try? handle.close() }
            try handle.seekToEnd()
            if let reader = try? FileHandle(forReadingFrom: body) {
                defer { try? reader.close() }
                while let chunk = try reader.read(upToCount: 1 << 20), !chunk.isEmpty { try handle.write(contentsOf: chunk) }
            }
            try handle.close()
            let size = partSize(key)
            let total = range.total ?? info.expected
            if let total, size > total { remove(key); return .restart }
            guard Self.isWhole(size: size, expected: total) else {
                var updated = info
                updated.received = size
                if let total { updated.expected = total }
                try saveInfo(updated, key: key)
                return .incomplete
            }
            return .complete(try handOver(part, key: key))
        case 200..<300:
            guard Self.isWhole(size: Self.size(of: body), expected: expected) else { remove(key); return .restart }
            let file = FileManager.default.temporaryDirectory.appending(path: "magpie-audio-\(UUID().uuidString).tmp")
            try FileManager.default.moveItem(at: body, to: file)
            remove(key)
            return .complete(file)
        default:
            throw RangeError.status(status)
        }
    }

    /// Moves a finished file out to a temporary name the caller owns, and clears the key.
    private func handOver(_ file: URL, key: String) throws -> URL {
        let out = FileManager.default.temporaryDirectory.appending(path: "magpie-audio-\(UUID().uuidString).tmp")
        try FileManager.default.moveItem(at: file, to: out)
        remove(key)
        return out
    }

    /// Whether a downloaded file is all there: never empty, and the size the server announced when it did.
    public static func isWhole(size: Int64, expected: Int64?) -> Bool {
        guard size > 0 else { return false }
        guard let expected, expected > 0 else { return true }
        return size == expected
    }

    public static func parseContentRange(_ header: String) -> ContentRange? {
        guard let match = header.wholeMatch(of: /bytes (\d+)-(\d+)\/(\d+|\*)/),
              let start = Int64(match.1), let end = Int64(match.2), end >= start else { return nil }
        return ContentRange(start: start, end: end, total: Int64(match.3))
    }

    // MARK: - Files

    static func keyOf(_ name: String) -> String? {
        guard let dot = name.firstIndex(of: "."), extensions.contains(String(name[name.index(after: dot)...])) else { return nil }
        let key = String(name[..<dot])
        return isKey(key) ? key : nil
    }

    public static func size(of url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    private func prepare() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.protect(directory)
    }

    /// Kept out of backups, and readable after first unlock on iOS (as the store's files).
    static func protect(_ url: URL) throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var target = url
        try target.setResourceValues(values)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                              ofItemAtPath: url.path)
        #endif
    }
}
