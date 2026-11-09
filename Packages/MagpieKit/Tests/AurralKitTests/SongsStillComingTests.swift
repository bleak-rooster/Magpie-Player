import Foundation
import MagpieCore
import Testing
@testable import AurralKit

/// Round 24 C (owner, 2026-11-08, item 6; D213): "a page like the active Lidarr downloads page, for Aurral: songs not
/// yet downloaded, their state". The pure rules of "Songs still coming": which section each song is in, which rows
/// are the user's own (the only ones with actions), and Done recently's limit.

private func job(_ id: String, _ status: String?, flow: String = "flow-1", upgrade: String? = nil) -> AurralJob {
    var j = AurralJob(id: id, flowId: flow, artistName: "Low", trackName: "Song \(id)", status: status)
    j.upgradeForJobId = upgrade
    return j
}

private let mine = AurralFlow(id: "flow-1", name: "Discover Weekly", ownerUserId: 1, ownerUsername: "jordan")
private let sams = AurralFlow(id: "flow-sam", name: "Late Night", ownerUserId: 2, ownerUsername: "sam")

@Suite struct SongsStillComingTests {
    /// Each Aurral 2.13 job state has one section: blocked is Held for review, failed and saved (D199's "missing", never
    /// a quality upgrade's job) Not found, pending Looking, downloading Downloading, done Done recently. Cancelled,
    /// cancel_requested and a state Magpie doesn't know aren't shown (nothing to wait for, nothing to decide).
    @Test func downloads_groupsByState() {
        let jobs = [job("1", "blocked"), job("2", "failed"), job("3", "saved"), job("4", "pending"), job("5", "downloading"),
                    job("6", "done"), job("7", "cancelled"), job("8", "cancel_requested"), job("9", nil),
                    job("10", "weird"), job("11", "failed", upgrade: "6"), job("12", "BLOCKED")]
        let board = SongsStillComing.board([.init(item: mine, own: true, jobs: jobs)])
        #expect(board.held.map(\.job.id) == ["1", "12"])
        #expect(board.notFound.map(\.job.id) == ["2", "3"])
        #expect(board.looking.map(\.job.id) == ["4"])
        #expect(board.downloading.map(\.job.id) == ["5"])
        #expect(board.doneRecently.map(\.job.id) == ["6"])
        #expect(!board.isEmpty)
        #expect(SongsStillComing.section(of: job("x", "blocked")) == .held)
        #expect(SongsStillComing.section(of: job("x", "cancelled")) == nil)
    }

    /// Done recently: the last 10 Aurral lists (it gives no finish time), across every flow and playlist.
    @Test func doneRecentlyIsTheLastTen() {
        let jobs = (0..<14).map { job("d\($0)", "done") }
        let board = SongsStillComing.board([.init(item: mine, own: true, jobs: jobs)])
        #expect(board.doneRecently.map(\.job.id) == (4..<14).map { "d\($0)" })
        #expect(SongsStillComing.doneShown == 10)
    }

    /// Empty: nothing held, missing, looked for or downloading ("Nothing is waiting on Aurral."), whatever is done.
    @Test func downloads_emptyState() {
        let board = SongsStillComing.board([.init(item: mine, own: true, jobs: [job("1", "done"), job("2", "cancelled")])])
        #expect(board.isEmpty)
        #expect(!board.doneRecently.isEmpty)
        #expect(SongsStillComing.board([]).isEmpty)
    }

    /// Each row carries its flow or playlist and whether it is the user's own; another user's rows are read only. A
    /// job listed twice (two reads of one item) is one row.
    @Test func rowsCarryTheirItemAndOwner() {
        let board = SongsStillComing.board([.init(item: mine, own: true, jobs: [job("1", "blocked"), job("1", "blocked")]),
                                            .init(item: sams, own: false, jobs: [job("2", "blocked", flow: "flow-sam")])])
        #expect(board.held.map(\.id) == ["flow-1/1", "flow-sam/2"])
        #expect(board.held.map(\.own) == [true, false])
        #expect(board.held.last?.item.ownerUsername == "sam")
    }
}

/// Fix round 1 (I4, ruling): a song's progress and Aurral's words about it, read leniently. Aurral 2.13's public job
/// (`rowToJob` / `toPublicJob`, read at tag v2.13.0) carries `error` and no progress; `progress`, `message` and
/// `statusMessage` are accepted too, for a later Aurral. Absent or odd: nil, never a trap.
@Suite struct JobProgressAndMessageTests {
    private func decode(_ fields: String) throws -> AurralJob {
        try #require(try AurralJob.decodeList(Data(#"[{"id":"1","trackName":"T","artistName":"A"\#(fields)}]"#.utf8)).first)
    }

    @Test func progressClampedAndScaled() throws {
        #expect(try decode(#","progress":42"#).progress == 42)
        #expect(try decode(#","progress":42.6"#).progress == 43)
        #expect(try decode(#","progress":0.5"#).progress == 50, "0–1 scaled")
        #expect(try decode(#","progress":250"#).progress == 100)
        #expect(try decode(#","progress":-3"#).progress == 0)
        #expect(try decode(#","progress":"37""#).progress == 37)
        #expect(try decode(#","progress":"lots""#).progress == nil)
        #expect(try decode(#","progress":1e308"#).progress == 100)
        #expect(try decode("").progress == nil)
    }

    @Test func messageTrimmedAndBounded() throws {
        #expect(try decode(#","error":"  No results on Soulseek  ""#).message == "No results on Soulseek")
        #expect(try decode(#","statusMessage":"Waiting for a slot""#).message == "Waiting for a slot")
        #expect(try decode(#","message":"Queued","error":"old""#).message == "Queued", "message first")
        #expect(try decode(#","error":"   ""#).message == nil)
        #expect(try decode(#","error":42"#).message == nil)
        let long = String(repeating: "a", count: 500)
        #expect(try decode(#","error":"\#(long)""#).message?.count == 200)
        #expect(try decode("").message == nil)
    }
}
