import Foundation
import MagpieCore
import NavidromeKit

/// T2 fix C1: a saved session whose addresses are all plain http to public hosts without the owner's consent
/// (saved by build 1, or the Keychain outlived a reinstall that cleared the consent). Nothing is sent until the
/// owner says yes (`allowSavedSession`) or signs in again.
struct SavedSessionAwaitingConsent: Equatable {
    let bases: [URL]
    let username: String
    /// The addresses to ask about; empty once the owner said no (Connect stays, filled in).
    var unencrypted: [URL]
}

extension AppModel {
    /// The saved addresses credentials may go to now, in order: encrypted, home or Tailscale, or consented.
    func sendableBases(_ endpoint: ServerEndpoint) -> [URL] {
        endpoint.bases.filter(plainHTTPConsent.allows)
    }

    func awaitConsent(for saved: SavedSession) {
        savedSessionAwaitingConsent = SavedSessionAwaitingConsent(
            bases: saved.endpoint.bases, username: saved.credentials.username,
            unencrypted: saved.endpoint.bases.filter { !plainHTTPConsent.allows($0) })
    }

    /// The owner said yes to the saved addresses: resume without asking for the password again.
    func allowSavedSession() {
        guard let pending = savedSessionAwaitingConsent else { return }
        allowPlainHTTP(pending.unencrypted)
        savedSessionAwaitingConsent = nil
        resumeSavedSession()
    }

    /// The owner said no: stay on Connect with the addresses and username filled in.
    func declineSavedSession() {
        savedSessionAwaitingConsent?.unencrypted = []
    }

    /// T2 fix round 2: the saved Lidarr is plain http to a public host without consent (a reinstall kept the
    /// Keychain, not the consent). `lidarrClient` is nil until the owner allows it in Settings › Lidarr.
    var lidarrAwaitingConsent: Bool {
        _ = plainHTTPConsentRevision   // observed: allowing it updates Settings
        return lidarr.map { !plainHTTPConsent.allows($0.base) } ?? false
    }

    /// The owner allowed the saved Lidarr's address: start using it.
    func allowLidarrAddress() {
        guard let base = lidarr?.base else { return }
        allowPlainHTTP([base])
        rebuildRunner()
    }
}
