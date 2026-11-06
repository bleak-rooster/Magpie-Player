import Foundation

/// Round 23 (owner, 2026-11-07, D193): which of slskd's downloads are a removed artist's, decided conservatively from
/// Lidarr's own record of what it imported for the artist (read before the artist goes: Lidarr drops an artist's
/// history with it).
///
/// Lidarr's `trackFileImported` history names where it picked each file up (`droppedPath`): the folder in slskd's
/// downloads folder (its last component, as Lidarr sees it through its own mount) and the file's name. A group of slskd's
/// transfers (one user, one remote folder) is the artist's only when at least one of its files has the name of a file
/// Lidarr imported from that folder, and it matches exactly one such folder. Then, per folder:
/// - every transfer of each matched group must be finished, and no unfinished download anywhere has the name of one of
///   its files (never anything in progress, for this album or another): otherwise the folder is left alone;
/// - the files that may go are the names of the groups' finished, complete transfers (never anything else in the folder);
/// - their transfer records go too.
/// When in doubt (no import record, a name that isn't safe, two folders claiming one group), nothing is planned.
public enum SlskdLeftovers {
    public struct Folder: Sendable, Equatable {
        /// The folder directly inside slskd's downloads folder.
        public var name: String
        /// The files in it that may go (complete downloads of the artist's grabs).
        public var files: Set<String>
        /// The finished transfer records to remove, by user.
        public var transfers: [Transfer]

        public struct Transfer: Sendable, Equatable, Hashable {
            public var username: String
            public var id: UUID
        }
    }

    /// At most this many folders and files are planned in one clean-up.
    public static let folderLimit = 25
    public static let fileLimit = 500

    /// `imported`: (folder, file) pairs from Lidarr's import history of the artist (`ImportedFrom.folderAndFile`).
    public static func plan(imported: [(folder: String, file: String)], transfers: [SlskdTransfer]) -> [Folder] {
        var evidence: [String: Set<String>] = [:]
        for pair in imported where SlskdRoute.isSafeName(pair.folder) && SlskdRoute.isSafeName(pair.file) {
            evidence[pair.folder, default: []].insert(pair.file)
        }
        guard !evidence.isEmpty else { return [] }
        let unfinishedNames = Set(transfers.filter { !$0.isFinished }.map(\.fileName))
        struct Key: Hashable { var username: String; var directory: String }
        let groups = Dictionary(grouping: transfers) { Key(username: $0.username, directory: $0.directory) }
        var byFolder: [String: [[SlskdTransfer]]] = [:]
        var blocked = Set<String>()
        for (_, group) in groups {
            let names = Set(group.map(\.fileName))
            let folders = evidence.filter { !$0.value.isDisjoint(with: names) }.map(\.key)
            guard folders.count <= 1, let folder = folders.first else {
                if folders.count > 1 { blocked.formUnion(folders) }   // one remote folder, two local ones: unclear
                continue
            }
            // Anything of it still under way (or another download of one of its names): this folder waits for nobody;
            // it is simply left as it is.
            if group.contains(where: { !$0.isFinished }) || !names.isDisjoint(with: unfinishedNames) {
                blocked.insert(folder)
                continue
            }
            byFolder[folder, default: []].append(group)
        }
        var out: [Folder] = []
        var fileCount = 0
        for folder in byFolder.keys.sorted() where !blocked.contains(folder) {
            let groups = byFolder[folder] ?? []
            let files = Set(groups.flatMap { $0.filter(\.succeeded).map(\.fileName) }.filter(SlskdRoute.isSafeName))
            let records = groups.flatMap { $0 }.map { Folder.Transfer(username: $0.username, id: $0.id) }
            guard out.count < folderLimit, fileCount + files.count <= fileLimit else { break }
            fileCount += files.count
            out.append(Folder(name: folder, files: files, transfers: records))
        }
        return out
    }
}
