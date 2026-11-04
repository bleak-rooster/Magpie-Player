import AurralKit
import Foundation
import MagpieCore
import MagpieTestSupport
import Testing
@testable import Magpie

/// Round 14 A1 fix M3: what the signed-in Aurral user may do is read fresh (the bootstrap, at sign-in, at launch and on
/// each return to the foreground, at most every `aurralCapabilitiesInterval`), never taken from the login saved in the
/// Keychain. Callers gate on `aurralCapabilities` and `aurralCanAddFlow`.
extension DiscoverAppTests {
    @Test func permissionsAndCapabilitiesAreReadFresh() async throws {
        aurral.useAurral213()
        aurral.setRole("user", for: StubAurral.defaultUsername)
        aurral.setPermissions(.init(accessFlow: true, addArtist: true, addAlbum: true), for: StubAurral.defaultUsername)
        let model = try await signedIn()
        defer { model.signOut() }
        #expect(model.aurralCapabilities.trending && model.aurralCapabilities.editorialPlaylists)
        #expect(model.aurralCanAddFlow)
        #expect(model.aurralHasDownloader == true)
        let reads = { self.aurral.asked.filter { $0 == "GET /api/health/bootstrap" }.count }
        #expect(reads() == 1, "read once at sign-in")

        // The admin turns accessFlow off in Aurral. Within the interval nothing is asked again...
        aurral.setPermissions(.init(accessFlow: false, addArtist: true, addAlbum: true), for: StubAurral.defaultUsername)
        await model.refreshAurralCapabilities()
        #expect(reads() == 1 && model.aurralCanAddFlow)
        // ...after it, the next foreground read sees the change, though the saved login still says accessFlow.
        let later = Date().addingTimeInterval(AppModel.aurralCapabilitiesInterval + 1)
        model.discover.now = { later }
        await model.refreshAurralCapabilities()
        #expect(reads() == 2)
        #expect(!model.aurralCanAddFlow)
        #expect(aurralStore.load()?.login?.user.permissions?.accessFlow == true, "the saved login is stale; never gated on")

        // A failed read keeps the last answer.
        aurral.setDown(true)
        await model.refreshAurralCapabilities(force: true)
        #expect(model.aurralCapabilities.trending && !model.aurralCanAddFlow)
        aurral.setDown(false)

        // Signing out of Aurral forgets them.
        model.disconnectAurral()
        #expect(model.aurralCapabilities == .none && !model.aurralCanAddFlow && model.aurralHasDownloader == nil)
    }

    /// Aurral 2.10 (no API contract): nothing new, and Add flow stays hidden even for an admin.
    @Test func aurral210GetsNoNewCapabilities() async throws {
        let model = try await signedIn()
        defer { model.signOut() }
        #expect(model.aurralCapabilities == .none)
        #expect(!model.aurralCanAddFlow)
    }
}
