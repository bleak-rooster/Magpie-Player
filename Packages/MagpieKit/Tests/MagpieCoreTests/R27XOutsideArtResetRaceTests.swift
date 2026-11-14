import Foundation
import MagpieCore
import MagpieTestSupport
import Testing

/// Round 27 crash hunt (R27X): `B1OutsideArtTests.aCancelledLoadNeverPoisonsTheCache` failed under load. One cause was
/// in the loader: a screen that closed (`reset()`) while a picture's disk check was still running didn't stop that
/// load — it went on to the network, kept the picture and handed it to the screen that was gone.
///
/// The loader lives on the main actor and the disk check is its first suspension. The load is started as a main-actor
/// task and the test then yields once: the main queue runs jobs in order, so the load runs up to the disk check before
/// the test runs again, and it can't come back from the check until the test gives the main actor up — after the reset.
@MainActor @Suite struct R27XOutsideArtResetRaceTests {
    let dir = FileManager.default.temporaryDirectory.appending(path: "R27XOutsideArt-\(UUID().uuidString)")

    @Test func aResetDuringTheDiskCheckStopsTheLoad() async {
        let key = OutsideArtKey.releaseGroup(OutsideArtTests.rg)
        let t = MockTransport()
        t.stub(pathSuffix: "/front-250", body: b1png())
        let art = OutsideArtLoader(transport: t, userAgent: OutsideArtTests.ua, artistImage: nil, isOffline: { false },
                                   disk: OutsideArtDiskCache(directory: dir))
        let first = Task { @MainActor in await art.image(key) }
        await Task.yield()   // the load is now inside its disk check
        art.reset()
        #expect(await first.value == nil, "the screen closed: no picture for it")
        #expect(t.requests.isEmpty, "nothing asked of the network after the screen closed")
        #expect(art.cachedCount == 0)
        #expect(OutsideArtDiskCache(directory: dir).count == 0)

        #expect(await art.image(key) != nil, "asked again, it loads")
        #expect(t.requests.count == 1)
        try? FileManager.default.removeItem(at: dir)
    }
}
