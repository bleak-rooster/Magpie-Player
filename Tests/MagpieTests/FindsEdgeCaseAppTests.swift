import Foundation
import MagpieCore
import MagpieTestSupport
import Testing
@testable import Magpie

/// Task H1: edge cases of the app's Finds rules the feature suites don't reach: the finds identity's precedence
/// (native library id, Keep, the fail-closed rule), and the ListenBrainz token turning up after a locked launch.
@MainActor
@Suite struct FindsEdgeCaseAppTests {
    static func song(_ id: String, libraryId: Int?) -> Song {
        Song(id: id, title: "T", artist: "A", album: "B", duration: 200, libraryId: libraryId)
    }

    // MARK: - FindsIdentity (D29)

    /// A native library id decides on its own: the Finds library's id is a find even when Keep marked the id (the
    /// song is still listed there), any other library's id never is, even when the saved Finds ids list it.
    @Test func nativeLibraryIdDecides() {
        let identity = FindsIdentity()
        identity.set(libraryId: 2, songIds: ["s1"])
        identity.markKept("s1")
        #expect(identity.isFind(Self.song("s1", libraryId: 2)))
        #expect(!identity.isFind(Self.song("s1", libraryId: 1)))
        #expect(!identity.isFind(Self.song("other", libraryId: 1)))
        #expect(identity.isFind(Self.song("other", libraryId: 2)), "listed in the Finds library: a find, read or not")
    }

    /// Without a library id (Subsonic songs): Keep wins over the saved ids and over the fail-closed rule; an
    /// unknown id marked kept changes nothing else.
    @Test func keptIdsWithoutALibraryId() {
        let identity = FindsIdentity()
        identity.set(libraryId: 2, songIds: nil)   // not read yet: fails closed
        #expect(identity.isFind(Self.song("never-seen", libraryId: nil)))
        identity.markKept("kept")
        identity.markKept("not-in-finds-at-all")
        #expect(!identity.isFind(Self.song("kept", libraryId: nil)))
        #expect(identity.isFind(Self.song("never-seen", libraryId: nil)), "still fails closed for the rest")
        identity.set(libraryId: 2, songIds: ["kept", "f2"])   // a stale read still listing the kept song
        #expect(!identity.isFind(Self.song("kept", libraryId: nil)))
        #expect(identity.isFind(Self.song("f2", libraryId: nil)))
        #expect(!identity.isFind(Self.song("never-seen", libraryId: nil)), "known now: not a find")
    }

    /// Kept ids belong to the Finds library they were kept from: another library (or none) forgets them.
    @Test func anotherFindsLibraryForgetsKeptIds() {
        let identity = FindsIdentity()
        identity.set(libraryId: 2, songIds: ["s1"])
        identity.markKept("s1")
        identity.set(libraryId: 3, songIds: nil)
        #expect(identity.isFind(Self.song("s1", libraryId: nil)), "fails closed again for the new library")
        identity.set(libraryId: nil, songIds: ["s1"])
        #expect(!identity.isFind(Self.song("s1", libraryId: nil)), "no Finds library: nothing is a find")
        #expect(!identity.isFind(Self.song("s1", libraryId: 2)))
        identity.set(libraryId: 2, songIds: ["s1"])
        #expect(identity.isFind(Self.song("s1", libraryId: nil)), "kept ids were forgotten with the library")
    }

    /// Security FM2: a ready find's song counts as a find before any read lists it, with or without a Finds library
    /// id; a native library id and Keep still decide first; sign-out forgets it.
    @Test func readyFindsCountBeforeAnyRead() {
        let identity = FindsIdentity()
        identity.markLanded("landed")
        identity.setRequestFinds(["listed"])
        #expect(identity.isFind(Self.song("landed", libraryId: nil)), "no Finds library known: still a find")
        identity.set(libraryId: 2, songIds: ["older"])
        #expect(identity.isFind(Self.song("landed", libraryId: nil)) && identity.isFind(Self.song("listed", libraryId: nil)))
        #expect(!identity.isFind(Self.song("landed", libraryId: 1)), "listed in another library: not a find")
        identity.markKept("listed")
        #expect(!identity.isFind(Self.song("listed", libraryId: nil)), "kept wins")
        identity.setRequestFinds([])
        #expect(identity.isFind(Self.song("landed", libraryId: nil)), "landed stays for the session")
        identity.forgetAccount()
        #expect(!identity.isFind(Self.song("landed", libraryId: nil)))
    }

    // MARK: - ListenBrainz token after a locked launch

    /// Final review I3 / Task 7.1c: a launch before first unlock reads the token as absent. When it turns up, the
    /// token generation moves on (Home's "Made for you" reads again); reading the same thing again changes nothing.
    @Test func tokenTurningUpBumpsTheGeneration() {
        let tokens = LockableTokenStore()
        let model = AppModel(store: SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.tests.\(UUID().uuidString)")),
                             lidarrStore: MemoryLidarrStore(), tokenStore: tokens, matchIndexDirectory: nil,
                             dataDirectory: nil, gateDefaultsSuite: "magpie-tests-gate-\(UUID().uuidString)",
                             transport: MockTransport(), probeTransport: MockTransport(), engine: FakeEngine(),
                             defaults: UserDefaults(suiteName: UUID().uuidString)!, systemNowPlaying: false,
                             notifications: false)
        #expect(!model.hasListenBrainzToken)
        let before = model.listenBrainzTokenGeneration
        #expect(!model.reloadKeychainItems())
        #expect(model.listenBrainzTokenGeneration == before, "still locked: nothing changed")

        tokens.unlock(with: "lb-token")
        #expect(!model.reloadKeychainItems(), "no Lidarr turned up")
        #expect(model.hasListenBrainzToken)
        #expect(model.listenBrainzTokenGeneration == before + 1)
        model.reloadKeychainItems()
        #expect(model.listenBrainzTokenGeneration == before + 1, "the same token again: no reload")

        tokens.clear()
        model.reloadKeychainItems()
        #expect(!model.hasListenBrainzToken && model.listenBrainzTokenGeneration == before + 2)
        #expect(model.madeForYouShelf.isEmpty)
    }
}
