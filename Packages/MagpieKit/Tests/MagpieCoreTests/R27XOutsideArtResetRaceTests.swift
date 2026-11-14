import CryptoKit
import Darwin
import Foundation
import MagpieCore
import MagpieTestSupport
import Testing

/// Round 27 crash hunt (R27X): `B1OutsideArtTests.aCancelledLoadNeverPoisonsTheCache` failed under load. One cause was
/// in the loader: a screen that closed (`reset()`) while a picture's disk check was still running didn't stop that
/// load — it went on to the network, kept the picture and handed it to the screen that was gone. The disk check is
/// held open here with a named pipe in the picture's place, so the reset lands inside it every time.
@MainActor @Suite struct R27XOutsideArtResetRaceTests {
    let dir = FileManager.default.temporaryDirectory.appending(path: "R27XOutsideArt-\(UUID().uuidString)")

    @Test func aResetDuringTheDiskCheckStopsTheLoad() async throws {
        let key = OutsideArtKey.releaseGroup(OutsideArtTests.rg)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let digest = SHA256.hash(data: Data(key.token.utf8)).map { String(format: "%02x", $0) }.joined()
        let pipe = dir.appending(path: digest).path
        #expect(mkfifo(pipe, 0o600) == 0)

        let t = MockTransport()
        t.stub(pathSuffix: "/front-250", body: b1png())
        let art = OutsideArtLoader(transport: t, userAgent: OutsideArtTests.ua, artistImage: nil, isOffline: { false },
                                   disk: OutsideArtDiskCache(directory: dir))
        async let first = art.image(key)
        // Opening the pipe to write returns only once the loader has opened it to read: it is inside the disk check.
        let writer = await withCheckedContinuation { (done: CheckedContinuation<Int32, Never>) in
            DispatchQueue.global().async { done.resume(returning: open(pipe, O_WRONLY)) }
        }
        #expect(writer >= 0)
        art.reset()
        close(writer)   // the disk check ends: nothing kept there
        #expect(await first == nil, "the screen closed: no picture for it")
        #expect(t.requests.isEmpty, "nothing asked of the network after the screen closed")
        #expect(art.cachedCount == 0)

        unlink(pipe)
        #expect(await art.image(key) != nil, "asked again, it loads")
        try? FileManager.default.removeItem(at: dir)
    }
}
