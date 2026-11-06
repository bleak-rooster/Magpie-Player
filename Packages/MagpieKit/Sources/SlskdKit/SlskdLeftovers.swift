import Foundation

/// Round 23 (owner, 2026-11-07, D193): which of slskd's downloads are a removed artist's, decided conservatively from
/// Lidarr's own record of what it imported for the artist (read before the artist goes: Lidarr drops an artist's
/// history with it).
///
/// Lidarr's `trackFileImported` history names where it picked each file up (`droppedPath`): the folder in slskd's
/// downloads folder (its last component, as Lidarr sees it through its own mount) and the file's name. Fix round 1 I1: a
/// group of slskd's transfers (one user, one remote folder) is the artist's only when
/// - the last component of its own remote folder is that folder's name, exactly, and
/// - every song it downloaded completely (by its file name's extension) is one Lidarr imported from that folder,
/// so another album downloaded into a folder of the same name ("CD1", "Greatest Hits") that merely shares a track name is
/// never the artist's. Then, per folder:
/// - every transfer of each matched group must be finished, and no unfinished download anywhere has the name of one of
///   its files (never anything in progress, for this album or another): otherwise the folder is left alone;
/// - the files that may go are only the names Lidarr imported from that folder, of the groups' complete transfers
///   (pictures, notes and anything else stay, and so does the folder then);
/// - the records that go are only of those transfers.
/// When in doubt (no import record, a name that isn't safe), nothing is planned.
public enum SlskdLeftovers {
    public struct Folder: Sendable, Equatable {
        /// The folder directly inside slskd's downloads folder.
        public var name: String
        /// The files in it that may go (complete downloads of the artist's grabs that Lidarr imported).
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

    /// The extensions counted as songs: a group's every complete song must be one Lidarr imported.
    static let songExtensions: Set<String> = ["flac", "mp3", "m4a", "aac", "ogg", "oga", "opus", "wav", "aif", "aiff",
                                              "alac", "ape", "wv", "wma", "dsf", "dff"]

    static func isSong(_ name: String) -> Bool {
        guard let dot = name.lastIndex(of: ".") else { return false }
        return songExtensions.contains(name[name.index(after: dot)...].lowercased())
    }

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
        for (key, group) in groups {
            let folder = SlskdTransfer.lastComponent(key.directory)
            guard let names = evidence[folder] else { continue }   // its own folder isn't one Lidarr imported from
            let songs = Set(group.filter { $0.succeeded && isSong($0.fileName) }.map(\.fileName))
            guard !songs.isEmpty, songs.isSubset(of: names) else { continue }   // a song Lidarr never imported: not ours
            if group.contains(where: { !$0.isFinished }) || !Set(group.map(\.fileName)).isDisjoint(with: unfinishedNames) {
                blocked.insert(folder)   // anything of it still under way: the folder is left as it is
                continue
            }
            byFolder[folder, default: []].append(group)
        }
        var out: [Folder] = []
        var fileCount = 0
        for folder in byFolder.keys.sorted() where !blocked.contains(folder) {
            let names = evidence[folder] ?? []
            let mine = (byFolder[folder] ?? []).flatMap { $0 }.filter { $0.succeeded && names.contains($0.fileName) }
            let files = Set(mine.map(\.fileName))
            guard out.count < folderLimit, fileCount + files.count <= fileLimit else { break }
            fileCount += files.count
            out.append(Folder(name: folder, files: files,
                              transfers: mine.map { Folder.Transfer(username: $0.username, id: $0.id) }))
        }
        return out
    }
}
