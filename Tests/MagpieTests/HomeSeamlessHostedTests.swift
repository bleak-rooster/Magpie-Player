import Foundation
import MagpieCore
import MagpieTestSupport
import os
import SwiftUI
import Testing
import UIKit
@testable import Magpie

private let ok = Data(#"{"subsonic-response":{"status":"ok","version":"1.16.1"}}"#.utf8)
private let loginJSON = Data(#"""
{"id":"u1","isAdmin":true,"name":"Admin","subsonicSalt":"salt","subsonicToken":"tok","token":"jwt","username":"admin"}
"""#.utf8)
private let failedBody = Data(#"{"subsonic-response":{"status":"failed","version":"1.16.1","error":{"code":0,"message":"no"}}}"#.utf8)

private func albumListBody(_ id: String) -> Data {
    Data(#"{"subsonic-response":{"status":"ok","version":"1.16.1","albumList2":{"album":[{"id":"\#(id)","name":"\#(id)","artist":"A","songCount":1}]}}}"#.utf8)
}

/// P5 (priority round): the owner's "I have to refresh Home regularly", reproduced on the real `HomeView` in a window.
/// A section whose first read fails must be read again by itself, with no pull to refresh and no change to Home's
/// layout: before P5 nothing read it again until a key change, so "Couldn't load" stayed until the owner pulled.
@MainActor @Suite(.serialized) final class HomeSeamlessHostedTests {
    let tmp = FileManager.default.temporaryDirectory.appending(path: "HomeSeamlessHostedTests-\(UUID().uuidString)")
    let store = SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.tests.\(UUID().uuidString)"))
    let defaults = UserDefaults(suiteName: "HomeSeamlessHostedTests.\(UUID().uuidString)")!
    let transport = HostSwitchTransport()

    deinit {
        store.clear()
        try? FileManager.default.removeItem(at: tmp)
    }

    /// Signed in; Home shows Jump back in and Recently added. `newest` fails its first `failNewest` reads.
    func signedInModel(failNewest: Int) async throws -> AppModel {
        transport.inner.stub(pathSuffix: "/rest/ping", body: ok)
        transport.inner.stub(method: "POST", pathSuffix: "/auth/login", body: loginJSON)
        transport.inner.stub(pathSuffix: "/api/song", body: Data("[]".utf8), headers: ["X-Total-Count": "0"])
        let failuresLeft = OSAllocatedUnfairLock(initialState: failNewest)
        transport.inner.stub(pathSuffix: "/rest/getAlbumList2") { request in
            let type = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
                .queryItems?.first { $0.name == "type" }?.value ?? ""
            if type == "newest", failuresLeft.withLock({ left in defer { left -= 1 }; return left > 0 }) {
                return MockTransport.Response(status: 200, body: failedBody)
            }
            return MockTransport.Response(status: 200, body: albumListBody(type == "newest" ? "n1" : "r1"))
        }
        let model = AppModel(store: store, lidarrStore: MemoryLidarrStore(), tokenStore: MemoryTokenStore(),
                             matchIndexDirectory: nil, dataDirectory: tmp, transport: transport, probeTransport: transport,
                             engine: FakeEngine(), defaults: defaults, systemNowPlaying: false, notifications: false,
                             network: FakeNetwork(.wifi), audioFetcher: FakeFetcher())
        try await model.signIn(urls: [URL(string: "http://192.168.1.2:4533")!], username: "admin", password: "pw")
        await model.downloads!.settled()
        model.updatePreferences {
            $0.downloads.preDownload = 0
            $0.layout.home = OrderedVisibility(HomeSection.allCases.map {
                .init(item: $0, visible: $0 == .jumpBackIn || $0 == .recentlyAdded)
            })
        }
        return model
    }

    private func newestReads() -> Int {
        transport.inner.requests.filter { request in
            request.url?.path.hasSuffix("getAlbumList2") == true && request.url?.query?.contains("type=newest") == true
        }.count
    }

    @Test func failedSectionIsReadAgainWithoutARefresh() async throws {
        let model = try await signedInModel(failNewest: 1)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = UIHostingController(rootView: NavigationStack { HomeView() }
            .environment(model).magpieTheme(model.theme))
        window.isHidden = false
        defer { window.isHidden = true }

        #expect(await eventually(5) { self.newestReads() >= 1 }, "Home never read Recently added")
        // The first backoff step is 5 s: within 8 s Home has read it again, by itself.
        #expect(await eventually(8) { self.newestReads() >= 2 }, "a failed section waited for a pull to refresh")
    }
}
