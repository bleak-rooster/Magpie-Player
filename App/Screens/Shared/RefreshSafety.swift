import Foundation

/// Round 13 Z2 (plan item 2): pull to refresh never says "Couldn't load this" for a read that was only cut short.
///
/// Root cause (reproduced by `Round13UITests.testPullToRefreshKeepsThePage` with every request 1.5 s slower, as on
/// the owner's server): SwiftUI cancels a `.refreshable` action while the page it belongs to is still updating (here,
/// the artist page's own first load filling in Popular, "Not yet in your library" and the Lidarr line). The reload's
/// request ended with URLSession's `.cancelled`, and the page took that for a failure and replaced what it showed
/// with the error. A second pull, with the page settled, wasn't cancelled and loaded.
///
/// Now (1) the pull's work runs in a task of its own, so the refresh finishes even when SwiftUI lets go of it, and
/// (2) a load cut short is never an error, and a page that shows something keeps it when a reload fails: the error
/// shows only when there is nothing else to show.
enum RefreshSafety {
    /// Runs a pull's work in a task SwiftUI can't cancel, and waits for it (the spinner stays until it is done).
    @MainActor static func run(_ work: @escaping @MainActor () async -> Void) async {
        await Task { @MainActor in await work() }.value
    }
}

extension Loadable {
    /// What a page shows after its load threw `error`: unchanged when the load was cut short (a cancellation is
    /// never an error) or something is already on screen; otherwise the failure.
    func failing(_ error: any Error) -> Loadable {
        if AppModel.isCancellation(error) || value != nil { return self }
        return .failed(BrowseErrorCopy.message(for: error))
    }
}
