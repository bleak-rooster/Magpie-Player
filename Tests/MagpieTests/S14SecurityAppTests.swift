import AurralKit
import Foundation
import MagpieCore
import MagpieTestSupport
import Testing
import UIKit
@testable import Magpie

/// Round 14 security S14 L3 (D118): the picture mapping (`<data>/aurral-image-proxy`) is kept out of backups and goes,
/// with the pictures kept in memory, when the owner signs out of Aurral.
extension DiscoverAppTests {
    @Test func signingOutOfAurralErasesThePictureMapping() async throws {
        let (model, _) = try await previewModel()
        defer { model.signOut() }
        let client = try #require(model.aurralClient)
        let art = try #require(try await client.trending().songs?.items.first?.artwork)
        #expect(await model.aurralArtwork(art, side: 45) != nil)
        let directory = AurralImageProxies.directory(model.dataDirectory)
        let file = directory.appending(path: AurralImageProxy.serverKey(client.base) + ".json")
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        #expect(try file.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        let key = "\(AurralImageProxies.key(client.base))|\(art.raw)#45" as NSString
        #expect(AurralArtworkCache.shared.object(forKey: key) != nil)

        model.disconnectAurral()
        #expect(!FileManager.default.fileExists(atPath: directory.path), "the mapping folder is gone")
        #expect(AurralArtworkCache.shared.object(forKey: key) == nil, "and the pictures kept in memory")
        try await Task.sleep(for: .milliseconds(100))   // the dropped proxy's erase runs
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }
}
