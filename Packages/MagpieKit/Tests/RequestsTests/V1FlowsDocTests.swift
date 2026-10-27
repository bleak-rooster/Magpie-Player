import Foundation
import MagpieCore
import Testing
@testable import Requests

/// Verify V1: docs/FLOWS.md §4 (requests file: atomic, excluded from backup) and §3a (sign-out erases it).
@Suite struct V1RequestsFileDocTests {
    @Test func requestsFileIsExcludedFromBackupAndErasedOnSignOut() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "V1Requests-\(UUID().uuidString)")
        let url = RequestStore.defaultURL(in: dir, instance: "abc123")
        #expect(url.path.hasSuffix("/Magpie/requests-abc123.json"))
        let store = RequestStore(fileURL: url)
        try await store.save([])
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        // No temporary file is left next to it (atomic write).
        let siblings = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        #expect(siblings == ["requests-abc123.json"])
        await store.erase()
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
