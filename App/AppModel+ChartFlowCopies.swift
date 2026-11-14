import AurralKit
import Foundation
import MagpieCore
import NavidromeKit
import Search

/// What a chart's rows show: the song each playable row plays (the main library's copy, else the chart flow's), and
/// the rows whose song the flow is still getting.
struct ChartRows: Equatable, Sendable {
    var copies: [Int: Song] = [:]
    var onItsWay: Set<Int> = []
    /// Fix round 1 (design H1): rows whose copy is the chart flow's (played in full, never said to be "in your library").
    var flowRows: Set<Int> = []

    /// Fix round 1 (I1): the playable rows' songs in chart order, and where `index` is among them.
    func playOrder(from index: Int) -> (songs: [Song], start: Int)? {
        let owned = copies.keys.sorted()
        guard let start = owned.firstIndex(of: index) else { return nil }
        return (owned.compactMap { copies[$0] }, start)
    }

    /// Fix round 1 (I1): the rows with no song to play in full (their previews are still what plays).
    func previewOnly(_ count: Int) -> [Int] { (0..<count).filter { copies[$0] == nil } }
}

/// Round 27 D2 (owner item 16, 2026-11-14): when a chart has its own flow (D130–D134), Trending's rows the flow holds
/// play the flow's songs in full, shown exactly as library rows (no preview, no Try or Add, no words about where they
/// live); a row whose song is still downloading says "On its way"; any other row keeps its preview and menu (D317,
/// D318, per owner Q4).
///
/// - Only a **confirmed** flow (`ChartFlowBook`, the server listed it) whose Navidrome playlist Discover knows
///   (`discover.playlists`, its flow id the flow's playlist id). Genre charts with a flow work the same.
/// - The playlist is read once each time a chart list opens (one `getPlaylist`), and again on pull to refresh; the
///   matching is `ChartFlowMatch` (the flow's jobs from Discover's read, then the strict title rule with
///   `TopSongIdentity.titleKey`).
/// - The main library's copy still comes first (`libraryCopies(of:)`, unchanged: A's top songs call it too).
/// Nothing is written anywhere.
extension AppModel {
    /// The chart's confirmed flow and its Navidrome playlist, when Discover knows it.
    func chartFlowPlaylist(for chart: TrendingChart) -> (flow: ChartFlow, playlistId: String)? {
        guard aurralSetUp, let flow = chartFlow(for: chart), flow.confirmed,
              let playlist = discover.playlists.first(where: { $0.flow.id == flow.playlistId })?.playlist else { return nil }
        return (flow, playlist.id)
    }

    /// Each row's song in the chart flow's playlist (one read of it), and the rows still on their way. Empty without a
    /// flow, offline or on a failed read.
    func chartFlowCopies(chart: TrendingChart, songs: [ChartSong]) async -> ChartFlowMatch.Result {
        guard session != nil, !isOffline, !songs.isEmpty, let (flow, playlistId) = chartFlowPlaylist(for: chart) else {
            return ChartFlowMatch.Result()
        }
        guard let read = try? await request({ try await $0.playlist(id: playlistId) }) else { return ChartFlowMatch.Result() }
        let jobs = discover.jobs.filter { $0.flowId == flow.playlistId }
        return ChartFlowMatch.match(chart: Self.flowTracks(songs), songs: read.1, jobs: jobs, titleKey: TopSongIdentity.titleKey)
    }

    /// What a chart list shows: the main library's copies first, then the chart flow's songs (`chart` nil: the library's
    /// only).
    func chartRows(chart: TrendingChart?, songs: [ChartSong]) async -> ChartRows {
        let main = await libraryCopies(of: songs)
        guard let chart else { return ChartRows(copies: main) }
        let combined = ChartFlowMatch.combined(main: main, flow: await chartFlowCopies(chart: chart, songs: songs))
        return ChartRows(copies: combined.copies, onItsWay: combined.onItsWay,
                         flowRows: Set(combined.copies.keys.filter { main[$0] == nil }))
    }

    /// Fix round 1 (M4, design M2): what a chart list's rows depend on beyond its songs: the flow's playlist and its
    /// songs' states (ids and status), so the rows read again when Discover loads or a download finishes.
    func chartFlowSignature(_ chart: TrendingChart?) -> String {
        guard let chart, let (flow, playlistId) = chartFlowPlaylist(for: chart) else { return "" }
        let jobs = discover.jobs.filter { $0.flowId == flow.playlistId }.map { "\($0.id):\($0.status ?? "")" }.sorted()
        return playlistId + "|" + jobs.joined(separator: ",")
    }
}

/// Round 27 D2: the words for Trending's flow rows and the flow control (plan §8; nothing about where songs live).
enum ChartFlowRowCopy {
    static let onItsWay = "On its way"
    /// The row's VoiceOver words for it (design M1).
    static let onItsWayNote = "on its way"
    /// Fix round 1 (I1, design M3; plan §8 amendment): plays the chart's playable rows in order.
    static let play = "Play"
    static let onItsWaySymbol = "arrow.down.circle.dotted"
    /// Under the chart's flow control (D319).
    static let keepsUp = "Keeps up with the chart once a day."
}
