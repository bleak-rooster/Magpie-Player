import DesignSystem
import MagpieCore
import Requests
import SwiftUI

/// R17 / R20: back to a request from wherever its item shows. A "Not in your library" song, album or artist row that
/// already has a live request shows that request's status instead of Try, and opens the request's page: never a
/// second Try. Requests are matched by recording (MBID, else title and artist) and by album release group; the runner
/// joins a Try for another song on a release already on its way (G7). When the request is Ready, its song row turns
/// into the library song in place (the runner's ready event; views never poll).
enum RequestLinks {
    /// What a not-yet song row is right now.
    enum SongRow: Equatable {
        /// No live request: Try (or Ask for it).
        case tryIt
        /// On its way (or Ready, its song not known yet): the row opens the request's page.
        case request(RequestID)
        /// Ready: the library song, played like any other library row.
        case library(Song, RequestID)
    }

    /// Requests a row leads back to: on their way, or Ready. A stopped or failed one can be tried again.
    static func isLinkable(_ request: MagpieRequest) -> Bool { request.isActive || request.state == .ready }

    /// The live request for this song, the newest first.
    static func request(for recording: ExternalRecording, in requests: [MagpieRequest]) -> MagpieRequest? {
        requests.last { isLinkable($0) && RequestRunner.sameSong($0.recording, recording) }
    }

    /// The live request bringing in this album (release group).
    static func request(releaseGroup: MBID?, in requests: [MagpieRequest]) -> MagpieRequest? {
        guard let releaseGroup else { return nil }
        return requests.last { isLinkable($0) && $0.plan?.releaseGroupMBID == releaseGroup }
    }

    /// The newest live request for a song by this artist.
    static func request(artist: MBID?, in requests: [MagpieRequest]) -> MagpieRequest? {
        guard let artist else { return nil }
        return requests.last { isLinkable($0) && ($0.plan?.artistMBID ?? $0.recording.artistMBID) == artist }
    }

    static func songRow(for recording: ExternalRecording, in requests: [MagpieRequest],
                        readySongs: [RequestID: Song]) -> SongRow {
        guard let request = request(for: recording, in: requests) else { return .tryIt }
        if request.state == .ready, let song = readySongs[request.id] { return .library(song, request.id) }
        return .request(request.id)
    }
}

/// What a request's page offers, in order (R17, R20).
enum RequestPageAction: Equatable {
    case play, keep, notForMe, findAnotherCopy, checkAgain, stopLooking, remove

    static func actions(for r: MagpieRequest) -> [RequestPageAction] {
        var actions: [RequestPageAction] = []
        if r.state == .ready {
            actions.append(.play)
            // A Ready find: Play · Keep · Not for me… (R20), with nothing else under way for it.
            let free = r.isFind && r.keep == nil && !r.keepNeedsAttention && r.notForMe == nil && !r.notForMeNeedsAttention
                && r.lidarrArtistId != nil
            if free { actions.append(.keep) }
            if free, r.plan?.artistExistsInLidarr == false, r.albumId != nil { actions.append(.notForMe) }
        }
        if r.canSearchAgain { actions.append(.findAnotherCopy) }
        if r.isNotListed { actions.append(.checkAgain) }
        if RequestCopy.canCancel(r.state) {
            actions.append(.stopLooking)
        } else if !r.cleanupPending, r.state != .ready {
            actions.append(.remove)
        }
        return actions
    }
}

/// A not-yet song row, back to its request when it has one (R17): Try; the request's status, opening its page; or,
/// once Ready, the library song in place.
struct NotYetSongLink<TryRow: View>: View {
    @Environment(AppModel.self) private var app
    let recording: ExternalRecording
    let play: (Song) -> Void
    @ViewBuilder let tryRow: () -> TryRow

    var body: some View {
        switch RequestLinks.songRow(for: recording, in: app.requests, readySongs: app.readySongs) {
        case .tryIt:
            tryRow()
        case .library(let song, _):
            Button { play(song) } label: {
                Artwork(song.coverArtId, side: 48) { SongRow(song: song, state: .library, artwork: $0) }
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(.isButton)
        case .request(let id):
            if let request = app.magpieRequest(id) {
                NavigationLink(value: Route.request(id)) {
                    RequestRow(request: request, context: app.waitContext)
                }
                .padding(.horizontal, Tokens.Spacing.margin)
                // Ready but its song not read yet: read it once (the runner's ready event does this too).
                .task(id: request.state == .ready) { await app.rememberReadySong(request) }
            }
        }
    }
}

/// A not-yet album or artist row with a live request (R17): its status in text and symbol (D3), opening the request.
struct RequestedItemRow: View {
    @Environment(AppModel.self) private var app
    let title: String
    let detail: String
    let request: MagpieRequest
    private let themed = Themed()

    var body: some View {
        NavigationLink(value: Route.request(request.id)) {
            HStack(spacing: Tokens.Spacing.m) {
                RecordArt(side: 48, isSpinning: RequestCopy.group(request) == .inProgress && request.tier != .patient)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.body).lineLimit(2)
                    Text(detail).font(.footnote).foregroundStyle(themed.palette.ink2Color).lineLimit(1)
                    Label(RequestCopy.status(request, context: app.waitContext), systemImage: RequestCopy.symbol(request))
                        .font(.caption).foregroundStyle(themed.palette.accentInkColor).lineLimit(2)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(title), \(detail)")
            .accessibilityValue(RequestCopy.status(request, context: app.waitContext))
        }
    }
}
