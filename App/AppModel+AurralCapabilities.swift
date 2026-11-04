import AurralKit
import Foundation

/// Round 14 A1 fix M3 (D80): what the signed-in Aurral can do and what its user may do, read fresh from Aurral's
/// bootstrap at sign-in, at launch and on each return to the foreground (at most every `aurralCapabilitiesInterval`
/// unless forced). The login saved in the Keychain carries the permissions Aurral gave at that login only, so nothing
/// gates on it: callers gate on `aurralCapabilities`, `aurralCanAddFlow` and `aurralHasDownloader`.
extension AppModel {
    nonisolated static let aurralCapabilitiesInterval: TimeInterval = 5 * 60

    /// Reads the bootstrap again (the user too, from `/api/auth/me`, when the bootstrap doesn't name them). Offline,
    /// without Aurral, or within the interval, nothing is asked; a failure keeps the last answer.
    func refreshAurralCapabilities(force: Bool = false) async {
        guard let client = aurralClient, !isOffline else { return }
        if !force, let at = discover.bootstrapReadAt,
           discover.now().timeIntervalSince(at) < Self.aurralCapabilitiesInterval { return }
        let account = discover.connection?.account
        do {
            var bootstrap = try await client.bootstrap()
            if bootstrap.user == nil, bootstrap.capabilities.anyDiscover { bootstrap.user = try? await client.me() }
            guard discover.connection?.account == account else { return }   // another account meanwhile
            discover.bootstrap = bootstrap
            discover.bootstrapReadAt = discover.now()
        } catch {
            noteAurralError(error)
        }
    }

    /// What this Aurral can do, as last read (none before the first read, without Aurral, or on 2.10).
    var aurralCapabilities: AurralCapabilities {
        guard aurralSetUp else { return .none }
        return discover.bootstrap?.capabilities ?? .none
    }

    /// Add flow may show: this Aurral has Discover playlists and its user has accessFlow (or is an admin), as last read.
    var aurralCanAddFlow: Bool {
        aurralCapabilities.editorialPlaylists && discover.bootstrap?.user?.canAddFlow == true
    }

    /// Whether Aurral has a download source set up (nil: it hasn't said; Add flow then doesn't warn).
    var aurralHasDownloader: Bool? { aurralSetUp ? discover.bootstrap?.hasDownloader : nil }
}
