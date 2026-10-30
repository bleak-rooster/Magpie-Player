import Observation

/// "Reload artwork" (P4): a version per cover id, which `Artwork` views load again on. Reloaded covers skip the copy
/// saved with a download, so the server's image is fetched afresh.
@MainActor @Observable
final class ArtworkReloads {
    static let shared = ArtworkReloads()

    private var versions: [String: Int] = [:]

    func version(_ coverArtId: String) -> Int { versions[coverArtId] ?? 0 }

    func bump(_ coverArtId: String) { versions[coverArtId, default: 0] += 1 }

    /// Sign-out and sign-in: nothing reloaded carries over.
    func reset() { if !versions.isEmpty { versions = [:] } }
}
