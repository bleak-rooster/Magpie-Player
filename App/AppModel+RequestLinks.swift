import Foundation
import MagpieCore
import Requests

/// What Find another copy did (R17's Search again, R20's words).
enum FindAnotherCopyReply: Equatable {
    case started
    /// There's a copy coming: ask first ("Look for another copy?"), then call again with `removingCopy: true`.
    case needsConfirmation
    /// Asked less than 30 s ago ("You can ask again in a moment.").
    case tooSoon
    case failed(String)
}

/// R17: back to a request (its rows, the banner), Ready rows in place, stalled copies and Find another copy.
extension AppModel {
    static let stallLimitKey = "magpie.requests.stallLimit"

    /// Settings › New music "Give up on a stuck copy after": 1, 2, 5 or 10 min (default 1).
    var stallLimit: StallLimit {
        StallLimit(seconds: appDefaults.object(forKey: Self.stallLimitKey) as? Double ?? StallLimit.standard.seconds)
    }

    func setStallLimit(_ limit: StallLimit) {
        appDefaults.set(limit.seconds, forKey: Self.stallLimitKey)
        if let runner { Task { await runner.setStallLimit(limit.seconds) } }
    }

    /// The write gate's check for queue deletes: the requests on their way now (nil while there's no runner).
    func liveRequestIds() async -> Set<String>? {
        guard let runner else { return nil }
        return await runner.liveRequestIds
    }

    /// The library song a Ready request became, read once (the ready event, or a row showing a Ready request).
    func rememberReadySong(_ request: MagpieRequest) async {
        guard request.state == .ready, readySongs[request.id] == nil, let song = await readySong(request) else { return }
        readySongs[request.id] = song
    }

    /// Find another copy on the request page: drops the copy coming now (only after the owner confirmed) and looks
    /// again.
    func findAnotherCopy(_ id: RequestID, removingCopy: Bool) async -> FindAnotherCopyReply {
        guard let runner else { return .failed(RequestCopy.findAnotherFailed) }
        defer { pollRequests() }
        do {
            try await runner.searchAgain(id, removingDownload: removingCopy)
            return .started
        } catch RequestRunner.SearchAgainError.needsConfirmation {
            return .needsConfirmation
        } catch RequestRunner.SearchAgainError.tooSoon {
            return .tooSoon
        } catch {
            return .failed(RequestCopy.findAnotherFailed)
        }
    }

    /// Find another copy is held back for 30 s after the last one (R17).
    func findAnotherCopyWaits(_ request: MagpieRequest, now: Date = Date()) -> Bool {
        guard let last = request.searchAgainAt, now >= last else { return false }
        return now.timeIntervalSince(last) < RequestRunner.searchAgainInterval
    }
}
