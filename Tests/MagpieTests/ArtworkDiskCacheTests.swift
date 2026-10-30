import CryptoKit
import Foundation
import MagpieCore
import MagpieTestSupport
import NavidromeKit
import Testing
import UIKit
@testable import Magpie

private let ok = Data(#"{"subsonic-response":{"status":"ok","version":"1.16.1"}}"#.utf8)
private let loginJSON = Data(#"""
{"id":"u1","isAdmin":true,"name":"Admin","subsonicSalt":"salt","subsonicToken":"tok","token":"jwt","username":"admin"}
"""#.utf8)
private let home = URL(string: "http://192.168.1.2:4533")!

/// P4: artwork kept on disk until cleared, never keyed by a URL, served without a request, reloadable per item, and
/// gone with the account at sign-out. Artwork requests go to a stub (G0).
@MainActor @Suite(.serialized) final class ArtworkDiskCacheTests {
    let tmp = FileManager.default.temporaryDirectory.appending(path: "ArtworkDiskCacheTests-\(UUID().uuidString)")
    let store = SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.tests.\(UUID().uuidString)"))
    let defaults = UserDefaults(suiteName: "ArtworkDiskCacheTests.\(UUID().uuidString)")!
    let art = MockTransport()

    init() {
        let png = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).pngData { context in
            UIColor.orange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        art.stub(pathSuffix: "/rest/getCoverArt", body: png, headers: ["Content-Type": "image/png"])
        ArtworkCache.shared.removeAll()
        ArtworkCache.shared.transportForTesting = art
    }

    deinit {
        store.clear()
        try? FileManager.default.removeItem(at: tmp)
        Task { @MainActor in ArtworkCache.shared.transportForTesting = nil }
    }

    private func signedInModel() async throws -> AppModel {
        let transport = HostSwitchTransport()
        transport.inner.stub(pathSuffix: "/rest/ping", body: ok)
        transport.inner.stub(method: "POST", pathSuffix: "/auth/login", body: loginJSON)
        transport.inner.stub(pathSuffix: "/api/song", body: Data("[]".utf8), headers: ["X-Total-Count": "0"])
        let model = AppModel(store: store, lidarrStore: MemoryLidarrStore(), tokenStore: MemoryTokenStore(),
                             matchIndexDirectory: nil, dataDirectory: tmp, transport: transport,
                             probeTransport: transport, engine: FakeEngine(), defaults: defaults,
                             systemNowPlaying: false, notifications: false, network: FakeNetwork(.wifi),
                             audioFetcher: FakeFetcher())
        try await model.signIn(urls: [home], username: "admin", password: "pw")
        return model
    }

    private var artRequests: Int { art.requests.filter { $0.url?.path.hasSuffix("/rest/getCoverArt") == true }.count }

    private func file(_ model: AppModel, _ coverArtId: String, _ size: Int) async throws -> URL {
        let scope = try #require(model.navidromeScope)
        return try #require(await model.artworkDisk.url(scope: scope, coverArtId: coverArtId, size: size))
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    @Test func keyIsAHashOfIdAndSizeNeverAURLOrToken() async throws {
        let model = try await signedInModel()
        let expected = SHA256.hash(data: Data("al-1|300".utf8)).map { String(format: "%02x", $0) }.joined()
        #expect(ArtworkDiskCache.fileName(coverArtId: "al-1", size: 300) == expected)
        #expect(ArtworkDiskCache.fileName(coverArtId: "al-1", size: 300) != ArtworkDiskCache.fileName(coverArtId: "al-1", size: 600))
        _ = await model.artworkImage("al-1", size: 300)
        let url = try await file(model, "al-1", 300)
        #expect(exists(url))
        let path = url.path
        #expect(path.hasPrefix(tmp.appending(path: "Magpie/Artwork").path))
        #expect(url.lastPathComponent == expected)
        for leak in ["http", "192.168", "4533", "getCoverArt", "t=", "s=", "u=", "tok", "salt", "admin", "al-1"] {
            #expect(!path.contains(leak), "the path holds \(leak)")
        }
        let sent = try #require(art.requests.last?.url?.absoluteString)
        #expect(sent.contains("t=") || sent.contains("jwt"), "the request did carry auth, so the key had to avoid it")
    }

    @Test func aHitMakesNoRequestOnlineOrOffline() async throws {
        let model = try await signedInModel()
        #expect(await model.artworkImage("al-1", size: 300) != nil)
        #expect(artRequests == 1)
        ArtworkCache.shared.removeAll()   // memory gone (a relaunch): the disk serves it
        #expect(await model.artworkImage("al-1", size: 300) != nil)
        #expect(artRequests == 1, "served from disk without a request")
        model.updatePreferences { $0.downloads.offlineMode = .on }
        ArtworkCache.shared.removeAll()
        #expect(await model.artworkImage("al-1", size: 300) != nil, "offline: cached art shows")
        #expect(await model.artworkImage("al-2", size: 300) == nil, "offline: uncached shows the placeholder")
        #expect(artRequests == 1)
    }

    @Test func filesAreExcludedFromBackupAndProtectedUntilFirstUnlock() async throws {
        let model = try await signedInModel()
        _ = await model.artworkImage("al-1", size: 300)
        var url = try await file(model, "al-1", 300)
        url.removeAllCachedResourceValues()
        #expect(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        var folder = ArtworkDiskCache.folder(root: tmp)
        folder.removeAllCachedResourceValues()
        #expect(try folder.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        // The Simulator keeps no data-protection class (see V1FlowsDocAppTests); a device reports it.
        if let protection = try FileManager.default.attributesOfItem(atPath: url.path)[.protectionKey] as? FileProtectionType {
            #expect(protection == .completeUntilFirstUserAuthentication)
        }
    }

    @Test func clearEmptiesItAndTheSizeReadsZero() async throws {
        let model = try await signedInModel()
        _ = await model.artworkImage("al-1", size: 300)
        _ = await model.artworkImage("ar-1", size: 120)
        #expect(await model.artworkUsage > 0)
        #expect(DownloadsSettingsView.artworkText(84_000_000) == "Artwork \u{00B7} 84 MB")
        await model.clearArtworkCache()
        #expect(await model.artworkUsage == 0)
        let gone = try await file(model, "al-1", 300)
        #expect(!exists(gone))
        #expect(DownloadsSettingsView.artworkText(0) == "Artwork \u{00B7} Zero KB")
    }

    @Test func reloadDropsOnlyThatItemAndFetchesAgain() async throws {
        let model = try await signedInModel()
        _ = await model.artworkImage("al-1", size: 300)
        _ = await model.artworkImage("al-1", size: 600)
        _ = await model.artworkImage("al-2", size: 300)
        #expect(artRequests == 3)
        let before = ArtworkReloads.shared.version("al-1")
        await model.reloadArtwork("al-1")
        let small = try await file(model, "al-1", 300), large = try await file(model, "al-1", 600)
        let other = try await file(model, "al-2", 300)
        #expect(!exists(small) && !exists(large))
        #expect(exists(other), "the other cover stays")
        #expect(ArtworkReloads.shared.version("al-1") == before + 1, "its views load again")
        #expect(ArtworkCache.shared.cached(ArtworkCache.key(scope: model.artworkScope!, coverArtId: "al-1", size: 300)) == nil)
        #expect(await model.artworkImage("al-1", size: 300) != nil)
        #expect(artRequests == 4, "fetched again")
        #expect(await model.artworkImage("al-2", size: 300) != nil)
        #expect(artRequests == 4)
    }

    @Test func signOutRemovesTheScope() async throws {
        let model = try await signedInModel()
        _ = await model.artworkImage("al-1", size: 300)
        let scopeFolder = try await file(model, "al-1", 300).deletingLastPathComponent()
        #expect(exists(scopeFolder))
        let before = ArtworkCache.shared.generation   // what a fetch in flight at sign-out started with
        model.signOut()
        #expect(await eventually { !self.exists(scopeFolder) })
        // A write from before the sign-out is refused.
        await model.artworkDisk.save(Data([1]), scope: scopeFolder.lastPathComponent, coverArtId: "al-9", size: 300,
                                     generation: before)
        #expect(!exists(scopeFolder))
    }
}
