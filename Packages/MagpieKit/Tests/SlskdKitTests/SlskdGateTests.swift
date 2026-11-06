import Foundation
import Testing
import MagpieCore
import MagpieTestSupport
@testable import SlskdKit

/// Round 23 (owner, 2026-11-07, D192): Magpie's calls to slskd are an exact allow-list, the key goes only in
/// `X-API-Key`, and the write gate (off by default) changes only finished downloads' records and files directly
/// inside slskd's downloads folder, checked on fresh reads.
@Suite struct SlskdGateTests {
    static let base = URL(string: "https://nas.local/slskd")!
    static let album = "Aurora Field - Lowlands (2016)"

    struct Env {
        let slskd = FakeSlskd()
        let suite = "magpie-slskd-\(UUID().uuidString)"
        let client: SlskdClient
        let gate: SlskdWriteGate
        let done = UUID(), other = UUID(), running = UUID()

        init(on: Bool = true) async {
            client = SlskdClient(base: SlskdGateTests.base, apiKey: "test-slskd-key", transport: slskd)
            gate = SlskdWriteGate(client: client, defaultsSuite: suite)
            if on { await gate.setEnabled(true) }
            let (done, other, running) = (self.done, self.other, self.running)
            slskd.with { s in
                s.transfers = [
                    .init(id: done, username: "jordan", directory: "@@x\\Music\\Lowlands (2016)", file: "01 - Song.flac"),
                    .init(id: other, username: "jordan", directory: "@@x\\Music\\Lowlands (2016)", file: "02 - Other.flac"),
                    .init(id: running, username: "sam", directory: "@@y\\Another", file: "01 - Busy.flac", state: "InProgress"),
                ]
                s.folders = [SlskdGateTests.album: (["01 - Song.flac", "02 - Other.flac"], []),
                             "Another": (["01 - Busy.flac"], [])]
            }
        }
    }

    // MARK: - Routes

    @Test func routesAreExactlyTheFive() throws {
        let id = UUID(uuidString: "6f1c2a52-0000-4000-8000-000000000001")!
        let urls = [
            SlskdRoute.downloads.url(base: Self.base),
            SlskdRoute.downloadsFolder("Lowlands").url(base: Self.base),
            SlskdRoute.removeTransfer(username: "jo dan/x", id: id).url(base: Self.base),
            SlskdRoute.deleteFile(folder: "Lowlands", file: "01.flac").url(base: Self.base),
            SlskdRoute.deleteFolder("Lowlands").url(base: Self.base),
        ].map { $0?.absoluteString }
        #expect(urls == [
            "https://nas.local/slskd/api/v0/transfers/downloads",
            "https://nas.local/slskd/api/v0/files/downloads/directories/TG93bGFuZHM%3D",
            nil,   // a user name with a separator is never sent
            "https://nas.local/slskd/api/v0/files/downloads/files/TG93bGFuZHMvMDEuZmxhYw%3D%3D",
            "https://nas.local/slskd/api/v0/files/downloads/directories/TG93bGFuZHM%3D",
        ])
        #expect(SlskdRoute.removeTransfer(username: "jo dan", id: id).url(base: Self.base)?.absoluteString
                == "https://nas.local/slskd/api/v0/transfers/downloads/jo%20dan/6f1c2a52-0000-4000-8000-000000000001?remove=true")
        #expect(SlskdRoute.downloads.method == "GET" && SlskdRoute.downloadsFolder("a").method == "GET")
        #expect([SlskdRoute.removeTransfer(username: "a", id: id), .deleteFile(folder: "a", file: "b"), .deleteFolder("a")]
            .allSatisfy { $0.method == "DELETE" })
    }

    @Test(arguments: ["", ".", "..", "...", "....", "name.", "name ", "a/b", "a\\b", "C:", "a\u{0}", " lead", "trail ", String(repeating: "x", count: 256)])
    func unsafeNamesAreNeverSent(_ name: String) {
        #expect(!SlskdRoute.isSafeName(name))
        #expect(SlskdRoute.deleteFolder(name).url(base: Self.base) == nil)
        #expect(SlskdRoute.deleteFile(folder: "ok", file: name).url(base: Self.base) == nil)
        #expect(SlskdRoute.deleteFile(folder: name, file: "ok").url(base: Self.base) == nil)
    }

    @Test func theKeyGoesOnlyInItsHeader() async throws {
        let env = await Env()
        _ = try await env.client.downloads()
        let request = try #require(env.slskd.requests.first)
        #expect(request.value(forHTTPHeaderField: "X-API-Key") == "test-slskd-key")
        #expect(request.url?.absoluteString.contains("test-slskd-key") == false)
        env.slskd.with { $0.apiKey = "another" }
        await #expect(throws: SlskdError.unauthorized) { try await env.client.downloads() }
    }

    @Test func readsDownloadsAndAFolder() async throws {
        let env = await Env()
        let transfers = try await env.client.downloads()
        #expect(Set(transfers.map(\.fileName)) == ["01 - Song.flac", "02 - Other.flac", "01 - Busy.flac"])
        #expect(transfers.first { $0.id == env.running }?.isFinished == false)
        #expect(transfers.first { $0.id == env.done }?.succeeded == true)
        #expect(try await env.client.folder(Self.album)?.files.count == 2)
        #expect(try await env.client.folder("Nothing") == nil)
    }

    // MARK: - The gate

    @Test func offByDefaultSendsNothing() async throws {
        let env = await Env(on: false)
        #expect(await env.gate.enabled == false)
        await #expect(throws: SlskdGateError.disabled) { try await env.gate.perform(.deleteFolder(Self.album)) }
        #expect(env.slskd.requests.isEmpty, "nothing read while it's off")
    }

    @Test func aFinishedAlbumsFilesFolderAndRecordsGo() async throws {
        let env = await Env()
        try await env.gate.perform(.deleteFile(folder: Self.album, file: "02 - Other.flac"))
        try await env.gate.perform(.deleteFile(folder: Self.album, file: "01 - Song.flac"))
        try await env.gate.perform(.deleteFolder(Self.album))
        try await env.gate.perform(.removeTransfer(username: "jordan", id: env.done))
        #expect(env.slskd.with { $0.deleted } == ["file \(Self.album)/02 - Other.flac", "file \(Self.album)/01 - Song.flac",
                                                   "folder \(Self.album)", "record \(env.done.uuidString.lowercased())"])
    }

    /// Fix round 1 M2: a folder is deleted only once it is empty (slskd deletes a folder with everything in it): a
    /// folder still holding files is refused, whatever the caller says.
    @Test func aFolderGoesOnlyWhenEmpty() async throws {
        let env = await Env()
        await #expect(throws: SlskdGateError.self) {
            try await env.gate.perform(.deleteFolder(Self.album))
        }
        #expect(env.slskd.writes.isEmpty)
    }

    @Test func nothingInProgress() async throws {
        let env = await Env()
        await #expect(throws: SlskdGateError.self) { try await env.gate.perform(.deleteFile(folder: "Another", file: "01 - Busy.flac")) }
        await #expect(throws: SlskdGateError.self) { try await env.gate.perform(.deleteFolder("Another")) }
        await #expect(throws: SlskdGateError.self) { try await env.gate.perform(.removeTransfer(username: "sam", id: env.running)) }
        // A finished copy whose name another download (under way) also has: not now.
        env.slskd.with { s in
            s.transfers.append(.init(username: "sam", directory: "@@y\\Else", file: "01 - Song.flac", state: "Queued, Remotely"))
        }
        await #expect(throws: SlskdGateError.self) { try await env.gate.perform(.deleteFile(folder: Self.album, file: "01 - Song.flac")) }
        #expect(env.slskd.writes.isEmpty)
    }

    @Test func onlyWhatSlskdDownloaded() async throws {
        let env = await Env()
        env.slskd.with { s in s.folders[Self.album]?.files.append("cover.jpg") }
        // A file slskd has no finished download of, and a folder holding it or anything not named, or a subfolder.
        await #expect(throws: SlskdGateError.self) { try await env.gate.perform(.deleteFile(folder: Self.album, file: "cover.jpg")) }
        await #expect(throws: SlskdGateError.self) {
            try await env.gate.perform(.deleteFolder(Self.album))
        }
        env.slskd.with { s in s.folders["Sub"] = (["01 - Song.flac"], ["Disc 2"]) }
        await #expect(throws: SlskdGateError.self) { try await env.gate.perform(.deleteFolder("Sub")) }
        // A record of another user, or one slskd doesn't list.
        await #expect(throws: SlskdGateError.self) { try await env.gate.perform(.removeTransfer(username: "sam", id: env.done)) }
        await #expect(throws: SlskdGateError.self) { try await env.gate.perform(.removeTransfer(username: "jordan", id: UUID())) }
        // A path outside the downloads folder can't be named.
        await #expect(throws: SlskdGateError.self) { try await env.gate.perform(.deleteFolder("..")) }
        await #expect(throws: SlskdGateError.self) { try await env.gate.perform(.deleteFile(folder: "../etc", file: "passwd")) }
        #expect(env.slskd.writes.isEmpty)
    }

    @Test func unreadableSendsNothing() async throws {
        let env = await Env()
        env.slskd.with { $0.down = true }
        await #expect(throws: SlskdGateError.unconfirmed) { try await env.gate.perform(.deleteFolder(Self.album)) }
        #expect(env.slskd.writes.isEmpty)
    }

    @Test func remoteFileManagementOffIsSaid() async throws {
        let env = await Env()
        env.slskd.with { $0.remoteFileManagement = false }
        await #expect(throws: SlskdError.unauthorized) {
            try await env.gate.perform(.deleteFile(folder: Self.album, file: "01 - Song.flac"))
        }
        #expect(env.slskd.with { $0.deleted }.isEmpty)
    }

    @Test func theSwitchBelongsToOneSlskd() async throws {
        let env = await Env()
        let other = SlskdWriteGate(client: SlskdClient(base: Self.base, apiKey: "another-key", transport: env.slskd),
                                   defaultsSuite: env.suite)
        #expect(await env.gate.enabled == true)
        #expect(await other.enabled == false)
    }
}
