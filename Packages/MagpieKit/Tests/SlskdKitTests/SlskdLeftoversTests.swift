import Foundation
import Testing
@testable import SlskdKit

/// Round 23 (D193): which slskd downloads are a removed artist's: only groups tied to a file Lidarr imported from that
/// folder, only finished ones, and never a folder something is still downloading into.
@Suite struct SlskdLeftoversTests {
    static func t(_ user: String, _ dir: String, _ file: String, _ state: String = "Completed, Succeeded") -> SlskdTransfer {
        SlskdTransfer(id: UUID(), username: user, filename: dir + "\\" + file, directory: dir, state: state)
    }

    static let imported: [(folder: String, file: String)] = [("Lowlands (2016)", "01 - Song.flac"),
                                                             ("Lowlands (2016)", "02 - Other.flac")]

    @Test func theImportedFoldersFinishedGroupIsPlanned() {
        let a = Self.t("jordan", "@@x\\Lowlands (2016)", "01 - Song.flac")
        let b = Self.t("jordan", "@@x\\Lowlands (2016)", "02 - Other.flac")
        let failed = Self.t("jordan", "@@x\\Lowlands (2016)", "03 - Gone.flac", "Completed, Errored")
        let unrelated = Self.t("sam", "@@y\\Somebody Else", "01 - Theirs.flac")
        let plan = SlskdLeftovers.plan(imported: Self.imported, transfers: [a, b, failed, unrelated])
        #expect(plan.count == 1)
        #expect(plan.first?.name == "Lowlands (2016)")
        #expect(plan.first?.files == ["01 - Song.flac", "02 - Other.flac"], "a failed transfer left no file to delete")
        #expect(Set(plan.first?.transfers.map(\.id) ?? []) == [a.id, b.id],
                "never the unrelated user's, nor a record of a file Lidarr didn't import")
    }

    // MARK: - Fix round 1 I1: a group is tied by its own folder name and every song in it

    /// Another album downloaded by hand into a folder of the same name ("CD1"), sharing one track name with the find:
    /// it has a song Lidarr never imported, so it isn't the artist's, and none of its files or records are planned.
    @Test func aForeignGroupInAFolderOfTheSameNameSharingOneTrackIsLeftAlone() {
        let imported: [(folder: String, file: String)] = [("CD1", "01 - Intro.flac"), ("CD1", "02 - Song.flac")]
        let a1 = Self.t("jordan", "@@x\\Aurora Field\\Lowlands\\CD1", "01 - Intro.flac")
        let a2 = Self.t("jordan", "@@x\\Aurora Field\\Lowlands\\CD1", "02 - Song.flac")
        let b1 = Self.t("sam", "@@y\\Greatest Hits\\CD1", "01 - Intro.flac")
        let b2 = Self.t("sam", "@@y\\Greatest Hits\\CD1", "02 - Theirs.flac")
        let plan = SlskdLeftovers.plan(imported: imported, transfers: [a1, a2, b1, b2])
        #expect(plan.count == 1)
        #expect(Set(plan.first?.transfers.map(\.id) ?? []) == [a1.id, a2.id], "sam's records stay")
        #expect(plan.first?.files == ["01 - Intro.flac", "02 - Song.flac"])
    }

    /// A group whose own remote folder has another name is never tied to Lidarr's folder, whatever its file names.
    @Test func aGroupFromAnotherNamedFolderIsNeverMatched() {
        let a = Self.t("jordan", "@@x\\Lowlands", "01 - Song.flac")
        let b = Self.t("jordan", "@@x\\Lowlands", "02 - Other.flac")
        #expect(SlskdLeftovers.plan(imported: Self.imported, transfers: [a, b]).isEmpty)
    }

    /// Pictures and notes beside the songs are neither required nor planned: only the imported songs go.
    @Test func filesLidarrDidntImportStay() {
        let a = Self.t("jordan", "@@x\\Lowlands (2016)", "01 - Song.flac")
        let b = Self.t("jordan", "@@x\\Lowlands (2016)", "02 - Other.flac")
        let cover = Self.t("jordan", "@@x\\Lowlands (2016)", "cover.jpg")
        let plan = SlskdLeftovers.plan(imported: Self.imported, transfers: [a, b, cover])
        #expect(plan.first?.files == ["01 - Song.flac", "02 - Other.flac"])
        #expect(Set(plan.first?.transfers.map(\.id) ?? []) == [a.id, b.id])
    }

    @Test func nothingWithoutAnImportRecord() {
        let a = Self.t("jordan", "@@x\\Lowlands (2016)", "01 - Song.flac")
        #expect(SlskdLeftovers.plan(imported: [], transfers: [a]).isEmpty)
        // An import record of another file: the group isn't tied to it.
        let plan = SlskdLeftovers.plan(imported: [("Other Folder", "99 - Nope.flac")], transfers: [a])
        #expect(plan.isEmpty)
    }

    @Test func anythingUnderWayLeavesTheFolderAlone() {
        let a = Self.t("jordan", "@@x\\Lowlands (2016)", "01 - Song.flac")
        let b = Self.t("jordan", "@@x\\Lowlands (2016)", "02 - Other.flac", "InProgress")
        #expect(SlskdLeftovers.plan(imported: Self.imported, transfers: [a, b]).isEmpty)
        // Another album's download of the same name, still queued: not now either.
        let c = Self.t("sam", "@@y\\Elsewhere", "01 - Song.flac", "Queued, Remotely")
        #expect(SlskdLeftovers.plan(imported: Self.imported, transfers: [a, c]).isEmpty)
    }

    @Test func oneRemoteFolderClaimedByTwoLocalOnesIsUnclear() {
        let a = Self.t("jordan", "@@x\\Lowlands (2016)", "01 - Song.flac")
        let b = Self.t("jordan", "@@x\\Lowlands (2016)", "02 - Other.flac")
        let plan = SlskdLeftovers.plan(imported: [("Lowlands (2016)", "01 - Song.flac"), ("Lowlands", "02 - Other.flac")],
                                       transfers: [a, b])
        #expect(plan.isEmpty)
    }

    @Test func unsafeNamesAreNeverPlanned() {
        let a = Self.t("jordan", "@@x\\..", "01 - Song.flac")
        #expect(SlskdLeftovers.plan(imported: [("..", "01 - Song.flac")], transfers: [a]).isEmpty)
    }
}
