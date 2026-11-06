import Foundation
import Testing
@testable import SlskdKit

/// Round 23 (D193): which slskd downloads are a removed artist's: only groups tied to a file Lidarr imported from that
/// folder, only finished ones, and never a folder something is still downloading into.
@Suite struct SlskdLeftoversTests {
    static func t(_ user: String, _ dir: String, _ file: String, _ state: String = "Completed, Succeeded") -> SlskdTransfer {
        SlskdTransfer(id: UUID(), username: user, filename: dir + "\\" + file, directory: dir, state: state)
    }

    static let imported: [(folder: String, file: String)] = [("Lowlands (2016)", "01 - Song.flac")]

    @Test func theImportedFoldersFinishedGroupIsPlanned() {
        let a = Self.t("jordan", "@@x\\Lowlands (2016)", "01 - Song.flac")
        let b = Self.t("jordan", "@@x\\Lowlands (2016)", "02 - Other.flac")
        let failed = Self.t("jordan", "@@x\\Lowlands (2016)", "03 - Gone.flac", "Completed, Errored")
        let unrelated = Self.t("sam", "@@y\\Somebody Else", "01 - Theirs.flac")
        let plan = SlskdLeftovers.plan(imported: Self.imported, transfers: [a, b, failed, unrelated])
        #expect(plan.count == 1)
        #expect(plan.first?.name == "Lowlands (2016)")
        #expect(plan.first?.files == ["01 - Song.flac", "02 - Other.flac"], "a failed transfer left no file to delete")
        #expect(Set(plan.first?.transfers.map(\.id) ?? []) == [a.id, b.id, failed.id], "never the unrelated user's")
    }

    @Test func nothingWithoutAnImportRecord() {
        let a = Self.t("jordan", "@@x\\Lowlands (2016)", "01 - Song.flac")
        #expect(SlskdLeftovers.plan(imported: [], transfers: [a]).isEmpty)
        // Same file name, another folder Lidarr imported from: not this group's folder by name alone? The group matches
        // by file name, so the folder named in the record is the one planned, never another.
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
