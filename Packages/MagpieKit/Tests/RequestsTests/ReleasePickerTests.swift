import Testing
import Foundation
import MagpieCore
import ListenBrainzKit
@testable import Requests

private func id(_ n: Int) -> MBID { MBID(String(format: "00000000-0000-0000-0000-%012d", n))! }

private func rel(_ n: Int, _ type: String?, secondary: [String] = [], status: String? = "Official",
                 date: String? = "2000") -> MBRelease {
    MBRelease(id: id(100 + n), title: type == "Single" ? "song" : "r\(n)", date: date, status: status,   // a single: the song's own (D163)
              releaseGroup: MBReleaseGroup(id: id(n), primaryType: type, secondaryTypes: secondary))
}

private func rec(_ releases: [MBRelease]) -> MBRecording {
    MBRecording(id: id(999), title: "song", releases: releases, isrcs: [])
}

@Suite struct ReleasePickerTests {
    @Test func prefersSingle() {
        let r = rec([rel(1, "Album"), rel(2, "EP"), rel(3, "Single")])
        #expect(ReleasePicker.smallest(containing: r, available: nil) == id(3))
        #expect(ReleasePicker.smallest(containing: rec([rel(1, "Album"), rel(2, "EP")]), available: nil) == id(2))
    }

    @Test func restrictsToAvailable() {
        let r = rec([rel(1, "Album"), rel(2, "EP"), rel(3, "Single")])
        #expect(ReleasePicker.smallest(containing: r, available: [id(1), id(2)]) == id(2))
        #expect(ReleasePicker.smallest(containing: r, available: [id(1)]) == id(1))
    }

    @Test func noneAvailableIsNil() {
        let r = rec([rel(1, "Album")])
        #expect(ReleasePicker.smallest(containing: r, available: [id(42)]) == nil)
        #expect(ReleasePicker.smallest(containing: r, available: []) == nil)
        #expect(ReleasePicker.smallest(containing: rec([]), available: nil) == nil)
    }

    @Test func officialBeatsSmallerUnofficial() {
        let r = rec([rel(1, "Album"), rel(2, "Single", status: "Promotion")])
        #expect(ReleasePicker.smallest(containing: r, available: nil) == id(1))
    }

    @Test func secondaryTypesExcludedUnlessNothingElse() {
        let r = rec([rel(1, "Album"), rel(2, "Single", secondary: ["Live"]), rel(3, "EP", secondary: ["Remix"])])
        #expect(ReleasePicker.smallest(containing: r, available: nil) == id(1))
        let only = rec([rel(2, "Album", secondary: ["Compilation"]), rel(3, "Single", secondary: ["Live"])])
        #expect(ReleasePicker.smallest(containing: only, available: nil) == id(3))
        // The exclusion applies after restricting to available groups.
        #expect(ReleasePicker.smallest(containing: r, available: [id(2), id(3)]) == id(2))
    }

    @Test func earliestDateTiebreak() {
        let r = rec([rel(1, "Single", date: "2005-03"), rel(2, "Single", date: "2001"), rel(3, "Single", date: nil)])
        #expect(ReleasePicker.smallest(containing: r, available: nil) == id(2))
    }
}

/// Round 19: among singles, the one named after the song (its own single) before an earlier one it is the B-side of;
/// and the soundtrack or remix releases "Magpie Finds Extras" may bring in.
@Suite struct ReleasePickerRound19Tests {
    func rel(_ n: Int, _ title: String, _ type: String, _ date: String, secondary: [String] = [], status: String = "Official") -> MBRelease {
        MBRelease(id: mbid(800 + n), title: title, date: date, status: status,
                  releaseGroup: MBReleaseGroup(id: mbid(900 + n), primaryType: type, secondaryTypes: secondary))
    }

    @Test func theSongsOwnSingleBeforeAnEarlierBSide() {
        let r = MBRecording(id: mbid(1), title: "APT.", releases: [rel(1, "number one girl", "Single", "2024-01-01"),
                                                                     rel(2, "APT.", "Single", "2024-10-18"),
                                                                     rel(3, "rosie", "Album", "2024-12-06")])
        // Round 20: the B-side single comes after the album (rarely shared on its own).
        #expect(ReleasePicker.ordered(containing: r, available: nil) == [mbid(902), mbid(903), mbid(901)])
    }

    @Test func extrasAreSoundtracksAndRemixesOnly() {
        #expect(RequestRunner.fitsFindsExtras(rel(1, "KPop Demon Hunters", "Album", "2025", secondary: ["Soundtrack"])))
        #expect(RequestRunner.fitsFindsExtras(rel(2, "Dracula", "Single", "2025", secondary: ["Remix"])))
        #expect(!RequestRunner.fitsFindsExtras(rel(3, "Hits", "Album", "2025", secondary: ["Compilation"])))
        #expect(!RequestRunner.fitsFindsExtras(rel(4, "Live", "Album", "2025", secondary: ["Soundtrack", "Live"])))
        #expect(!RequestRunner.fitsFindsExtras(rel(5, "Plain", "Single", "2025")), "a studio release is the Finds profile's")
        #expect(!RequestRunner.fitsFindsExtras(rel(6, "Bootleg", "Single", "2025", secondary: ["Remix"], status: "Bootleg")))
    }
}
