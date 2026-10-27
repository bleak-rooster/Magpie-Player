import DesignSystem
import Foundation
import MagpieCore
import Requests

/// The Finds shelf (Task 6.2a), pure so tests can check it: the songs of the Finds library
/// (`libraryId == findsLibraryId`) and the Finds-mode requests still on their way.
///
/// Days left = 7 − whole days since the find arrived (`Song.createdAt`). Nothing leaves by itself in v1
/// (D10): a find past its 7 days stays, at 0. New finds = ready (listed in the Finds library) and not played yet.
struct FindsShelf: Equatable {
    /// The sample window, in days.
    static let sampleDays = 7

    struct Item: Equatable, Identifiable {
        let song: Song
        let daysLeft: Int
        let isNew: Bool
        /// The ready request Keep goes through (Task 6.2b); nil when there is none or a Keep is under way, and
        /// then the row offers no Keep.
        let keepRequest: RequestID?

        var id: String { song.id }
        /// A round record with a text status and a symbol (D3).
        var state: RowState { isNew ? .newFind : .find(daysLeft: daysLeft) }
        /// Finds come in at Fast Start quality: the "Sample" hallmark.
        var quality: Quality { .sample }
    }

    var newFinds: [Item]
    var finds: [Item]
    var onTheirWay: [MagpieRequest]

    var isEmpty: Bool { newFinds.isEmpty && finds.isEmpty && onTheirWay.isEmpty }

    /// Newest first; a song without a date last.
    init(songs: [Song], requests: [MagpieRequest], played: Set<String>, now: Date) {
        let items = songs.map { song in
            Item(song: song, daysLeft: song.createdAt.map { Self.daysLeft(since: $0, now: now) } ?? Self.sampleDays,
                 isNew: !played.contains(song.id), keepRequest: Self.keepRequest(for: song, in: requests))
        }.sorted { ($0.song.createdAt ?? .distantPast) > ($1.song.createdAt ?? .distantPast) }
        newFinds = items.filter(\.isNew)
        finds = items.filter { !$0.isNew }
        onTheirWay = requests.filter { $0.isFind && $0.isActive }
    }

    /// The ready request on this song with no Keep under way (the runner checks everything else on fresh state).
    static func keepRequest(for song: Song, in requests: [MagpieRequest]) -> RequestID? {
        requests.last {
            $0.state == .ready && $0.songId == song.id && $0.keep == nil && !$0.keepNeedsAttention && $0.lidarrArtistId != nil
        }?.id
    }

    /// 7 − whole days since `created`, between 0 and 7.
    static func daysLeft(since created: Date, now: Date) -> Int {
        let days = Int((now.timeIntervalSince(created) / (24 * 3600)).rounded(.down))
        return min(sampleDays, max(0, sampleDays - max(0, days)))
    }
}
