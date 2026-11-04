import AurralKit
import Foundation
import MagpieCore
import MagpieTestSupport
import Testing
@testable import Magpie

/// Round 14 A1 fix round 1 (D79 amendment): Aurral 2.13 hides its file paths, and its flow reads need accessFlow.
extension DiscoverAppTests {
    /// 2.13's jobs carry no `finalPath`: Aurral's library is learnt from the Discover playlists' own songs (library 2),
    /// never the main library, and left out of the lists as before.
    @Test func aurralsLibraryLearntWithoutJobPaths() async throws {
        aurral.useAurral213()
        let model = try await signedIn()
        defer { model.signOut() }
        #expect(model.discoverLibraryIds == [2])
        #expect(model.listedLibraryIds == [1] && model.mainLibraryId == 1)
        #expect(model.session?.client.libraryScope == [1])
    }

    /// A user without accessFlow can sign in (Recommended and Trending still work); Discover's flows just aren't there:
    /// no error, no "sign in again".
    @Test func signInWithoutAccessFlow() async throws {
        aurral.useAurral213()
        aurral.setRole("user", for: StubAurral.defaultUsername)
        aurral.setPermissions(.init(accessFlow: false, addArtist: true, addAlbum: true), for: StubAurral.defaultUsername)
        let model = try await signedIn()
        defer { model.signOut() }
        #expect(model.aurralSetUp && !model.discover.needsSignIn)
        #expect(try await model.discoverPlaylists().isEmpty)
        #expect(model.aurralCapabilities.trending && !model.aurralCanAddFlow)
    }

    /// accessFlow taken away later: Discover hides quietly, but what it learnt stays (D75: a Discover playlist stays
    /// Discover's, out of Playlists; D76: nothing wiped), and comes back when the permission does.
    @Test func losingAccessFlowHidesDiscoverWithoutWiping() async throws {
        aurral.useAurral213()
        aurral.setRole("user", for: StubAurral.defaultUsername)
        aurral.setPermissions(.init(accessFlow: true, addArtist: true, addAlbum: true), for: StubAurral.defaultUsername)
        let model = try await signedIn()
        defer { model.signOut() }
        #expect(try await model.discoverPlaylists().map(\.id).contains("pl-dw"))
        let libraries = model.discoverLibraryIds
        aurral.setPermissions(.init(accessFlow: false, addArtist: true, addAlbum: true), for: StubAurral.defaultUsername)
        await model.refreshDiscover(force: true)
        #expect(!model.discover.needsSignIn)
        #expect(try await model.discoverPlaylists().isEmpty, "Discover hides")
        #expect(model.isDiscoverPlaylist(id: "pl-dw"), "still kept out of Playlists")
        #expect(model.discoverLibraryIds == libraries, "Aurral's library stays out of the lists")
        aurral.setPermissions(.init(accessFlow: true, addArtist: true, addAlbum: true), for: StubAurral.defaultUsername)
        await model.refreshDiscover(force: true)
        #expect(try await model.discoverPlaylists().map(\.id).contains("pl-dw"))
    }
}
