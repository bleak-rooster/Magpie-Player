import Foundation
import MagpieCore

/// Scrobbling (spec §7, T17): the router sends each play to Navidrome and/or ListenBrainz and queues what can't go
/// yet. The queue goes again at launch, when the server answers again or offline mode ends, and when a ListenBrainz
/// token is saved.
extension AppModel {
    /// Sends the queued plays in the background (after `pending`, the launch's reconnect, when given).
    /// Signed out there is nothing queued (sign-out clears it).
    func drainScrobblesSoon(after pending: Task<Bool, Never>? = nil) {
        guard session != nil else { return }
        let scrobbles = self.scrobbles
        Task {
            _ = await pending?.value
            await scrobbles.drain()
        }
    }

    static let scrobbleQueueAccountKey = "magpie.scrobbleQueueAccount"

    /// The queue belongs to one account (`navidromeScope`): signing in to another clears it first. Sign-out clears it
    /// too; this covers a sign-in over a session, and a clear that couldn't finish.
    func scrobbleQueueBelongs(to scope: String?) {
        guard let scope else { return }
        if let owner = appDefaults.string(forKey: Self.scrobbleQueueAccountKey), owner != scope { scrobbles.clearQueue() }
        appDefaults.set(scope, forKey: Self.scrobbleQueueAccountKey)
    }

    func forgetScrobbleQueueAccount() {
        appDefaults.removeObject(forKey: Self.scrobbleQueueAccountKey)
    }

    /// Protected data became available: the queue file may be readable now; then what is queued goes.
    func reloadScrobbleQueue() {
        let scrobbles = self.scrobbles
        let signedIn = session != nil
        Task {
            await scrobbles.queue.reload()
            if signedIn { await scrobbles.drain() }
        }
    }

    /// Settings › Scrobbling's row: where plays go and when one counts, e.g. "Navidrome · 50% or 4 min".
    /// ListenBrainz is listed only with a token saved (without one nothing goes there).
    nonisolated static func scrobblingSummary(_ p: ScrobblePreferences, countPlays: Bool, hasToken: Bool) -> String {
        guard countPlays else { return "Off" }
        let destinations = [p.viaNavidrome ? "Navidrome" : nil, p.viaListenBrainz && hasToken ? "ListenBrainz" : nil]
            .compactMap { $0 }
        let rule = "\(p.rule.percent)%" + (p.rule.minutes.map { " or \($0) min" } ?? "")
        return destinations.isEmpty ? "Not sent" : destinations.joined(separator: " + ") + " · " + rule
    }
}
