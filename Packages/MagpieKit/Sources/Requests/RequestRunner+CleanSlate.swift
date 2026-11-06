import Foundation
import LidarrKit
import MagpieCore
import SlskdKit

/// Round 23 (D194): what was cleared before Magpie removed an artist it added. Saved before the first write (M6) and
/// never run twice for the same artist on one request.
public struct CleanSlate: Sendable, Codable, Equatable {
    public var artistId: Int
    public var startedAt: Date
    public var blocklistRemoved: Int?
    public var blocklistFailed = false
    public var slskdFilesRemoved: Int?
    public var slskdRecordsRemoved: Int?
    public var slskdFailed = false
    public var slskdSkipped = false

    public init(artistId: Int, startedAt: Date) { self.artistId = artistId; self.startedAt = startedAt }
}

extension RequestRunner {
    /// The slskd connection the runner may clean up through.
    public struct SlskdAccess: Sendable {
        public let client: SlskdClient
        public let gate: SlskdWriteGate
        public init(client: SlskdClient, gate: SlskdWriteGate) { self.client = client; self.gate = gate }
    }

    public func useSlskd(_ access: SlskdAccess?) { slskd = access }

    struct BlocklistIdsBody: Encodable, Sendable {
        var ids: [Int]
    }

    /// Round 23 (owner, 2026-11-07, D191–D194): a removed artist leaves a clean slate. Called by the two removals of an
    /// artist Magpie added (Not for me's last step, Stop looking's clean-up) once `mayRemoveArtist` proved it may go,
    /// right before its `DELETE /artist`, so Lidarr still has the artist's blocklist rows and history:
    /// 1. what Lidarr imported for the artist and from where (its history, read first: Lidarr drops it with the artist);
    /// 2. Lidarr's blocklist rows of the artist go (`ConfinedShape.blocklistCleanup`), so a later Try isn't refused by
    ///    stale rejections;
    /// 3. with slskd connected and "Allow Magpie to change Soulseek" on: its finished downloads of those grabs, files
    ///    and records (`SlskdLeftovers`, `SlskdWriteGate`).
    /// Saved before the first write (M6) and run once per artist and request: a lost answer is never sent again. A
    /// failure is recorded on the request and in the change log, and never holds the artist's removal back.
    func cleanSlateBeforeRemoving(artistId: Int, for id: RequestID) async {
        guard let r = request(id), r.cleanSlate?.artistId != artistId else { return }
        await mutate(id) { $0.cleanSlate = CleanSlate(artistId: artistId, startedAt: self.now()) }
        do { try await persist() } catch {
            await mutate(id) { $0.cleanSlate = nil }   // not saved: nothing is sent
            return
        }
        var imported: [ImportedFrom]?
        if slskd != nil { imported = try? await lidarr.importedFiles(artistId: artistId) }
        await clearBlocklist(id, artistId: artistId)
        await clearSlskd(id, imported: imported)
        try? await persist()
        if let slate = request(id)?.cleanSlate { await gate.note(Self.cleanSlateNote(slate)) }
    }

    /// The change log's line: what went, what was skipped, what failed.
    static func cleanSlateNote(_ s: CleanSlate) -> String {
        let blocklist = s.blocklistFailed ? "failed" : "\(s.blocklistRemoved ?? 0) removed"
        let slskd = s.slskdSkipped ? "changes off" : s.slskdFailed ? "failed (\(s.slskdFilesRemoved ?? 0) files, \(s.slskdRecordsRemoved ?? 0) records)"
            : s.slskdFilesRemoved == nil ? "not connected" : "\(s.slskdFilesRemoved ?? 0) files, \(s.slskdRecordsRemoved ?? 0) records"
        return "clean slate for artist \(s.artistId): blocklist \(blocklist); slskd \(slskd)"
    }

    private func clearBlocklist(_ id: RequestID, artistId: Int) async {
        let entries: [BlocklistEntry]
        do { entries = try await lidarr.blocklist(artistId: artistId) } catch {
            Log.logger("requests").error("clean slate: the blocklist couldn't be read")
            await mutate(id) { $0.cleanSlate?.blocklistFailed = true }
            return
        }
        let ids = Array(entries.map(\.id).prefix(500))
        guard !ids.isEmpty else {
            await mutate(id) { $0.cleanSlate?.blocklistRemoved = 0 }
            return
        }
        do {
            try await persist()   // M6
            _ = try await gate.send("DELETE", "blocklist/bulk", body: BlocklistIdsBody(ids: ids), confinedAs: .blocklistCleanup)
            await mutate(id) { $0.cleanSlate?.blocklistRemoved = ids.count }
        } catch {
            Log.logger("requests").error("clean slate: the blocklist stays: \(Log.category(of: error), privacy: .public)")
            await mutate(id) { $0.cleanSlate?.blocklistFailed = true }
        }
    }

    /// slskd's finished downloads of the artist's grabs (see `SlskdLeftovers`): a folder that holds only those files goes
    /// whole, otherwise only those files; then their records, only for a folder whose files went (or were gone already).
    private func clearSlskd(_ id: RequestID, imported: [ImportedFrom]?) async {
        guard let slskd else { return }
        guard await slskd.gate.enabled else {
            await mutate(id) { $0.cleanSlate?.slskdSkipped = true }
            return
        }
        guard let imported else {
            await mutate(id) { $0.cleanSlate?.slskdFailed = true }
            return
        }
        await mutate(id) { $0.cleanSlate?.slskdFilesRemoved = 0; $0.cleanSlate?.slskdRecordsRemoved = 0 }
        let plan: [SlskdLeftovers.Folder]
        do {
            plan = SlskdLeftovers.plan(imported: imported.compactMap(\.folderAndFile), transfers: try await slskd.client.downloads())
        } catch {
            await mutate(id) { $0.cleanSlate?.slskdFailed = true }
            return
        }
        for folder in plan {
            do {
                if let listing = try await slskd.client.folder(folder.name) {
                    let mine = listing.files.filter(folder.files.contains)
                    if !mine.isEmpty, mine.count == listing.files.count, listing.folders.isEmpty {
                        try await persist()   // M6
                        try await Self.gone { try await slskd.gate.perform(.deleteFolder(folder.name, only: folder.files)) }
                        await mutate(id) { $0.cleanSlate?.slskdFilesRemoved? += mine.count }
                    } else {
                        for file in mine {
                            try await persist()
                            try await Self.gone { try await slskd.gate.perform(.deleteFile(folder: folder.name, file: file)) }
                            await mutate(id) { $0.cleanSlate?.slskdFilesRemoved? += 1 }
                        }
                    }
                }
            } catch {
                Log.logger("requests").error("clean slate: slskd's files stay: \(Log.category(of: error), privacy: .public)")
                await mutate(id) { $0.cleanSlate?.slskdFailed = true }
                continue   // the records stay with files that couldn't go
            }
            for t in folder.transfers {
                do {
                    try await persist()
                    try await Self.gone { try await slskd.gate.perform(.removeTransfer(username: t.username, id: t.id)) }
                    await mutate(id) { $0.cleanSlate?.slskdRecordsRemoved? += 1 }
                } catch {
                    await mutate(id) { $0.cleanSlate?.slskdFailed = true }
                }
            }
        }
    }

    /// A 404 from slskd: gone already, which is what was wanted.
    private static func gone(_ body: () async throws -> Void) async throws {
        do { try await body() } catch SlskdError.http(status: 404) {}
    }
}
