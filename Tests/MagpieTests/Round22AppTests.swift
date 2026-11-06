import Foundation
import LidarrKit
import MagpieCore
import Requests
import Testing
@testable import Magpie

/// Round 22 (owner, 2026-11-06): the kept single's choice in the Add sheet after a Keep (D171), the playlists repointed
/// to the album's copy (D173), Albums / EPs / Singles chosen one by one (D175), and every new artist's add asking first
/// (D176, D177).
@MainActor @Suite struct Round22AppTests {
    static func offer(single: Bool, everything: Int, thisAlbum: Int) -> RequestRunner.BringInOffer {
        RequestRunner.BringInOffer(
            artistId: 42, artistName: "Aurora Field",
            options: [.everything: .init(albumIds: [53, 52, 54], available: 3, duration: 3_600, albumsOrEPs: everything),
                      .thisAlbum: .init(albumIds: [51], available: 1, duration: 2_400, title: "Lowlands", albumsOrEPs: thisAlbum),
                      .albumsAndEPs: .init(albumIds: [], available: 0, duration: nil)],
            followsNewReleases: false,
            keptSingle: single ? .init(albumId: 50, title: "Lowlands (single)") : nil)
    }

    /// D171: the sheet names the kept single only for a Single and a choice that brings in an album or EP.
    @Test func theSheetOffersTheChoiceOnlyForASingleWithAnAlbumComing() {
        let sizes = AppModel.afterKeepSizes(Self.offer(single: true, everything: 2, thisAlbum: 1))
        #expect(sizes[.wholeArtist]?.keptSingle == "Lowlands (single)")
        #expect(sizes[.thisAlbum]?.keptSingle == "Lowlands (single)")
        #expect(sizes[.wholeArtist]?.albumIds == [53, 52, 54])
        let onlySingles = AppModel.afterKeepSizes(Self.offer(single: true, everything: 0, thisAlbum: 1))
        #expect(onlySingles[.wholeArtist]?.keptSingle == nil, "only singles coming: no choice")
        let keptAlbum = AppModel.afterKeepSizes(Self.offer(single: false, everything: 2, thisAlbum: 1))
        #expect(keptAlbum[.wholeArtist]?.keptSingle == nil && keptAlbum[.thisAlbum]?.keptSingle == nil)
    }

    /// The words (British spelling, no service names).
    @Test func theSinglesWords() {
        #expect(BringInCopy.single("Lowlands (single)") == "The single \u{201C}Lowlands (single)\u{201D}")
        #expect(BringInCopy.keepSingle == "Keep it")
        #expect(BringInCopy.removeSingle == "Remove it once the album is here")
        #expect(BringInCopy.singleOutcome(.albumDidNotArrive) == "The single stays: the album didn't arrive.")
        #expect(BringInCopy.singleOutcome(.kept) == nil)
        let words = [BringInCopy.removeSingleNote, BringInCopy.keepSingleNote, BringInCopy.singleWaiting]
            + [KeptSingle.Outcome.removed, .noCopy, .notRemovable].compactMap(BringInCopy.singleOutcome)
        for w in words { #expect(!["Lidarr", "Navidrome", "Aurral"].contains { w.contains($0) }, "\(w)") }
    }

    /// D173: the single's song is replaced in place, every time it appears, nothing else moves.
    @Test func playlistsPointAtTheAlbumsCopyInPlace() {
        #expect(AppModel.repointed(["a", "single", "b", "single"], from: "single", to: "album")
                == ["a", "album", "b", "album"])
        #expect(AppModel.repointed(["a", "b"], from: "single", to: "album") == ["a", "b"])
    }

    /// D176: a new artist's add and the whole artist after a Keep always show the sheet; Add more still confirms.
    @Test func newAddsAlwaysAsk() {
        let mine = DownloadChoices.defaults
        #expect(AddRoute.route(withMyDefaults: true, defaults: mine, albumContext: false, candidates: 1, kind: .add) == .sheet(mine))
        #expect(AddRoute.route(withMyDefaults: true, defaults: mine, albumContext: true, candidates: 1,
                               kind: .afterKeep(kept: "Kept")) == .sheet(mine))
        #expect(AddRoute.route(withMyDefaults: true, defaults: mine, albumContext: false, candidates: 1, kind: .addMore) == .confirm(mine))
    }

    /// D175: the summary names exactly the kinds chosen.
    @Test func theKindsAreSaid() {
        #expect(NewMusicCopy.kinds(.standard) == "Their albums and EPs")
        #expect(NewMusicCopy.kinds(ReleaseTypes(albums: false, eps: false, singles: true)) == "Their singles")
        #expect(NewMusicCopy.kinds(ReleaseTypes(albums: true, eps: true, singles: true)) == "Their albums, EPs and singles")
        #expect(NewMusicCopy.kinds(ReleaseTypes(albums: true, eps: false, singles: true)) == "Their albums and singles")
        var c = DownloadChoices.defaults
        c.types = ReleaseTypes(albums: false, eps: true, singles: true)
        #expect(NewMusicCopy.summary(c, duration: nil) == "Their EPs and singles \u{00B7} Lossless")
    }
}
