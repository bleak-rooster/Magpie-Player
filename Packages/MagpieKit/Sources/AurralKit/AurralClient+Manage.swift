import Foundation
import MagpieCore

/// Round 24 B (owner, 2026-11-08): what a delete asked of Aurral came to.
public enum AurralDeleteResult: Sendable, Equatable {
    case queued(operationId: String?)
    case alreadyGone
}

public extension AurralClient {
    func deleteFlow(_ flowId: String) async throws -> AurralDeleteResult { throw AurralError.forbidden("todo") }
    func deleteSharedPlaylist(_ playlistId: String) async throws -> AurralDeleteResult { throw AurralError.forbidden("todo") }
    func approveHeldSong(_ jobId: String) async throws { throw AurralError.forbidden("todo") }
    func denyHeldSong(_ jobId: String) async throws { throw AurralError.forbidden("todo") }
}
