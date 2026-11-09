import Foundation
import MagpieCore

/// Round 24 B (owner, 2026-11-08): what a delete asked of Aurral came to (D208). Aurral 2.13 queues a delete
/// (`delete-flow` / `shared-playlist-delete`) and answers at once; the item leaves its status only when its worker has run
/// it, so the caller keeps showing "being removed" until the next status read no longer lists it.
public enum AurralDeleteResult: Sendable, Equatable {
    /// Aurral took it and queued the delete (`operationId` when it named one).
    case queued(operationId: String?)
    /// Aurral answered 404: the item is gone already, or was never the user's to see (2.13 answers both alike). Nothing
    /// was deleted by this call; for the phone it is gone either way.
    case alreadyGone
}

/// Round 24 B (owner, 2026-11-08, D207–D209): the owner's own Aurral items, managed from the phone.
/// - Delete flow / Delete playlist: `DELETE /api/playlists/flows/:id` and `DELETE /api/playlists/shared-playlists/:id`
///   (the routes round 16's Delete flow and round 15's Remove flow already used; this file is now their only send).
/// - A song Aurral held for review (its job `blocked`): `POST /api/playlists/jobs/:jobId/approve` imports the copy it
///   held back; `/deny` throws that copy away, records its source so Aurral never picks it again for this song, and sets
///   the song looking again ("Try another source").
/// Every call: a plain id only (refused unsent otherwise), the exact path, no query and no body; sent once (the only
/// resend is the one after a 401 a fresh login cured, as every Aurral call); a 403 is `notPermitted` (accessFlow off),
/// never "sign in again". Aurral checks only accessFlow for approve and deny, not whose song it is, so the caller offers
/// them on the user's own items only (D190).
public extension AurralClient {
    /// Delete flow: Aurral stops making it and removes its songs unless another playlist uses them. 404 is
    /// `alreadyGone`; any other refusal throws, and nothing is sent again.
    func deleteFlow(_ flowId: String) async throws -> AurralDeleteResult {
        guard AurralRoute.isPlainId(Substring(flowId)) else { throw AurralError.forbidden("delete flow \(flowId.count) chars") }
        do {
            let data = try await ok(method: AurralRoute.recipeFlowDeleteMethod, path: "api/playlists/flows/" + flowId)
            return .queued(operationId: (try? AurralQueued.decode(data))?.operationId)   // a 2xx is taken, whatever its words
        } catch AurralError.notFound { return .alreadyGone }
    }

    /// Delete playlist (a shared playlist: a chart flow, an Add flow copy, one made another way): Aurral removes it and
    /// the songs only it was keeping. 404 is `alreadyGone`; any other refusal throws, and nothing is sent again.
    func deleteSharedPlaylist(_ playlistId: String) async throws -> AurralDeleteResult {
        guard AurralRoute.isPlainId(Substring(playlistId)) else {
            throw AurralError.forbidden("delete playlist \(playlistId.count) chars")
        }
        do {
            let data = try await ok(method: AurralRoute.chartFlowDeleteMethod, path: "api/playlists/shared-playlists/" + playlistId)
            return .queued(operationId: (try? AurralQueued.decode(data))?.operationId)
        } catch AurralError.notFound { return .alreadyGone }
    }

    /// Approve: Aurral adds the copy it held back to the library. `notHeldAnyMore` when the song isn't held any more
    /// (Aurral's 404 or 409). Aurral imports the file before it answers, which can take a while.
    func approveHeldSong(_ jobId: String) async throws {
        guard AurralRoute.isPlainId(Substring(jobId)) else { throw AurralError.forbidden("approve \(jobId.count) chars") }
        do {
            _ = try await ok(method: AurralRoute.heldSongMethod, path: "api/playlists/jobs/" + jobId + "/approve")
        } catch AurralError.notFound { throw AurralError.notHeldAnyMore }
        catch AurralError.http(status: 409) { throw AurralError.notHeldAnyMore }
    }

    /// Try another source (Aurral's deny): Aurral won't use that copy again and looks for another. `notHeldAnyMore`
    /// when the song isn't held any more (Aurral's 404 or 409).
    func denyHeldSong(_ jobId: String) async throws {
        guard AurralRoute.isPlainId(Substring(jobId)) else { throw AurralError.forbidden("deny \(jobId.count) chars") }
        do {
            _ = try await ok(method: AurralRoute.heldSongMethod, path: "api/playlists/jobs/" + jobId + "/deny")
        } catch AurralError.notFound { throw AurralError.notHeldAnyMore }
        catch AurralError.http(status: 409) { throw AurralError.notHeldAnyMore }
    }
}
