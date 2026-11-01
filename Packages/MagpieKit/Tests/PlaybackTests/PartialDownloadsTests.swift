import Foundation
import Testing
import MagpieCore
@testable import Playback

/// R1: what a stopped download leaves in the store's `partials` folder, and the HTTP Range fallback.
@Suite final class PartialDownloadsTests {
    let tmp = FileManager.default.temporaryDirectory.appending(path: "PartialDownloadsTests-\(UUID().uuidString)")

    deinit { try? FileManager.default.removeItem(at: tmp) }

    var partials: PartialDownloads { PartialDownloads(directory: tmp.appending(path: "partials")) }

    func body(_ bytes: [UInt8]) -> URL {
        let incoming = tmp.appending(path: "incoming")
        try! FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        let url = incoming.appending(path: "body-\(UUID().uuidString).tmp")
        try! Data(bytes).write(to: url)
        return url
    }

    func original(received: Int64 = 0, expected: Int64? = nil) -> PartialDownloads.Info {
        PartialDownloads.Info(received: received, expected: expected, isOriginal: true, allowsCellular: false,
                              validator: "Mon, 26 Oct 2026 15:00:12 GMT", acceptsRanges: true, mimeType: "audio/mp4")
    }

    @Test func keyIsAHashNeverAServerString() {
        let key = PartialDownloads.key(songId: "../../etc/passwd", quality: .original)
        #expect(PartialDownloads.isKey(key))
        #expect(key.count == 64 && !key.contains("/"))
        #expect(key != PartialDownloads.key(songId: "../../etc/passwd", quality: .mp3High), "quality is part of it")
        #expect(!PartialDownloads.isKey("../x") && !PartialDownloads.isKey(""))
    }

    @Test func storageDirectoryIsInsideTheStore() {
        let store = AudioStore(root: tmp, scope: "s1")
        #expect(store.partialsDirectory == store.directory.appending(path: "partials", directoryHint: .isDirectory))
    }

    @Test func resumeDataAndInfoRoundTripAndCountTowardTheTotal() throws {
        let p = partials, key = PartialDownloads.key(songId: "s1", quality: .original)
        #expect(p.resumeData(key) == nil && p.info(key) == nil && p.totalBytes() == 0)
        try p.saveResumeData(Data(count: 300), key: key)
        try p.saveInfo(original(received: 2_100_000, expected: 8_400_000), key: key)
        #expect(p.resumeData(key)?.count == 300)
        #expect(p.info(key)?.received == 2_100_000)
        #expect(p.progress(key) == PartialDownloads.Progress(received: 2_100_000, expected: 8_400_000))
        #expect(p.keys() == [key])
        #expect(p.totalBytes() >= 300, "partials count toward the storage limit")
        let values = try p.directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true, "kept out of backups")
        p.remove(key)
        #expect(p.resumeData(key) == nil && p.info(key) == nil && p.keys().isEmpty)
    }

    @Test func aTranscodedPartialShowsNoProgress() throws {
        let p = partials, key = PartialDownloads.key(songId: "s1", quality: .mp3High)
        var info = original(received: 500, expected: 1000)
        info.isOriginal = false
        try p.saveInfo(info, key: key)
        #expect(p.progress(key) == nil, "it can't resume, so it isn't shown as paused part-way")
    }

    @Test func removeAllAndRetainOnly() throws {
        let p = partials
        let a = PartialDownloads.key(songId: "a", quality: .original), b = PartialDownloads.key(songId: "b", quality: .original)
        try p.saveResumeData(Data(count: 10), key: a)
        try p.saveResumeData(Data(count: 10), key: b)
        try Data("stray".utf8).write(to: p.directory.appending(path: "not-ours.txt"))
        #expect(p.retain(only: [a]) == [b])
        #expect(p.keys() == [a])
        #expect(FileManager.default.fileExists(atPath: p.directory.appending(path: "not-ours.txt").path),
                "only names Magpie writes are touched")
        p.removeAll()
        #expect(!FileManager.default.fileExists(atPath: p.directory.path))
    }

    // MARK: - Range fallback

    @Test func rangeRequestOnlyForAnOriginalWithAValidatorAndRanges() throws {
        let p = partials, key = PartialDownloads.key(songId: "s1", quality: .original)
        #expect(p.rangeRequest(key) == nil, "nothing on the phone")
        try p.adoptPart(body([1, 2, 3, 4]), info: original(received: 4, expected: 10), key: key)
        #expect(p.rangeRequest(key) == PartialDownloads.RangeRequest(range: "bytes=4-", ifRange: "Mon, 26 Oct 2026 15:00:12 GMT"))
        var info = original(received: 4, expected: 10)
        info.acceptsRanges = false
        try p.saveInfo(info, key: key)
        #expect(p.rangeRequest(key) == nil, "Accept-Ranges: none")
        info = original(received: 4, expected: 10)
        info.validator = nil
        try p.saveInfo(info, key: key)
        #expect(p.rangeRequest(key) == nil, "no ETag or Last-Modified to send as If-Range")
        info = original(received: 4, expected: 10)
        info.isOriginal = false
        try p.saveInfo(info, key: key)
        #expect(p.rangeRequest(key) == nil, "a transcoded stream is never byte-resumed")
    }

    @Test func rangeAppendsAndVerifiesTheFinalSize() throws {
        let p = partials, key = PartialDownloads.key(songId: "s1", quality: .original)
        try p.adoptPart(body([0, 1, 2, 3]), info: original(received: 4, expected: 10), key: key)
        let outcome = try p.appendRange(body([4, 5, 6, 7, 8, 9]), status: 206, contentRange: "bytes 4-9/10", key: key)
        guard case let .complete(file) = outcome else { Issue.record("not complete: \(outcome)"); return }
        #expect(try Data(contentsOf: file) == Data([0, 1, 2, 3, 4, 5, 6, 7, 8, 9]), "appended in order")
        #expect(p.keys().isEmpty, "the partial is handed over")
    }

    @Test func rangeShortOfTheTotalStaysPartial() throws {
        let p = partials, key = PartialDownloads.key(songId: "s1", quality: .original)
        try p.adoptPart(body([0, 1, 2, 3]), info: original(received: 4, expected: 10), key: key)
        let outcome = try p.appendRange(body([4, 5]), status: 206, contentRange: "bytes 4-9/10", key: key)
        #expect(outcome == .incomplete, "the server stopped early: the bytes so far are kept")
        #expect(p.info(key)?.received == 6)
        #expect(p.rangeRequest(key)?.range == "bytes=6-")
    }

    @Test func rangeThatDoesNotStartAtThePartialRestarts() throws {
        let p = partials, key = PartialDownloads.key(songId: "s1", quality: .original)
        try p.adoptPart(body([0, 1, 2, 3]), info: original(received: 4, expected: 10), key: key)
        let outcome = try p.appendRange(body([9]), status: 206, contentRange: "bytes 9-9/10", key: key)
        #expect(outcome == .restart)
        #expect(p.keys().isEmpty, "nothing mismatched is kept")
    }

    @Test func aFullResponseToARangeReplacesThePartial() throws {
        let p = partials, key = PartialDownloads.key(songId: "s1", quality: .original)
        try p.adoptPart(body([0, 1, 2, 3]), info: original(received: 4, expected: 10), key: key)
        // If-Range failed (the file changed on the server): the whole file comes back as 200.
        let outcome = try p.appendRange(body([7, 7, 7]), status: 200, contentRange: nil, key: key, expected: 3)
        guard case let .complete(file) = outcome else { Issue.record("not complete: \(outcome)"); return }
        #expect(try Data(contentsOf: file) == Data([7, 7, 7]))
        #expect(try p.appendRange(body([1]), status: 200, contentRange: nil, key: key, expected: 5) == .restart,
                "a whole file shorter than its Content-Length is refused")
    }

    @Test func rangeErrorStatusThrows() throws {
        let p = partials, key = PartialDownloads.key(songId: "s1", quality: .original)
        try p.adoptPart(body([0, 1]), info: original(received: 2, expected: 4), key: key)
        #expect(throws: PartialDownloads.RangeError.status(416)) {
            try p.appendRange(body([]), status: 416, contentRange: nil, key: key)
        }
    }

    @Test func verifiesSizes() {
        #expect(PartialDownloads.isWhole(size: 10, expected: 10))
        #expect(PartialDownloads.isWhole(size: 10, expected: nil), "no Content-Length: nothing to check against")
        #expect(!PartialDownloads.isWhole(size: 9, expected: 10))
        #expect(!PartialDownloads.isWhole(size: 0, expected: nil), "an empty file is never whole")
        #expect(PartialDownloads.parseContentRange("bytes 4-9/10") == .init(start: 4, end: 9, total: 10))
        #expect(PartialDownloads.parseContentRange("bytes 4-9/*") == .init(start: 4, end: 9, total: nil))
        #expect(PartialDownloads.parseContentRange("bytes */10") == nil)
        #expect(PartialDownloads.parseContentRange("garbage") == nil)
    }

    @Test func partialsCountTowardTheDownloadsLimit() async throws {
        let store = AudioStore(root: tmp, scope: "s1")
        let p = PartialDownloads(directory: store.partialsDirectory)
        try p.saveResumeData(Data(count: 600), key: PartialDownloads.key(songId: "x", quality: .original))
        let file = body(Array(repeating: 1, count: 500))
        await #expect(throws: AudioStoreError.downloadsFull) {
            try await store.add(file, metadata: AudioMetadata(Song(id: "s1", title: "T", artist: "A", album: "Al", duration: 1)),
                                quality: .original, kind: .download, reason: .song, fileExtension: "mp3",
                                downloadsLimit: 1000)
        }
    }

    /// Review M4: sizes show only when something is kept to resume from.
    @Test func progressOnlyWhenSomethingIsKept() throws {
        let p = PartialDownloads(directory: tmp.appending(path: "m4"))
        let key = PartialDownloads.key(songId: "m4", quality: .original)
        try p.saveInfo(.init(received: 2, expected: 8, isOriginal: true, allowsCellular: false, validator: nil,
                             acceptsRanges: false, mimeType: nil), key: key)
        #expect(p.progress(key) == nil, "counts alone: it will restart")
        try p.saveResumeData(Data("r".utf8), key: key)
        #expect(p.progress(key) == PartialDownloads.Progress(received: 2, expected: 8))
    }
}

/// R4: "Download all songs" keeps its songs with the artist's reason.
@Suite struct ArtistReasonTests {
    @Test func artistReasonRoundTrips() throws {
        let reasons: Set<DownloadReason> = [.artist("ar1"), .album("a1")]
        let data = try JSONEncoder().encode(reasons)
        #expect(try JSONDecoder().decode(Set<DownloadReason>.self, from: data) == reasons)
        #expect(DownloadReason.artist("ar1") != .album("ar1"))
    }
}
