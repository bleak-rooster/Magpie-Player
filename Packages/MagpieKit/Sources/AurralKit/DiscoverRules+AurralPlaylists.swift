import Foundation
import MagpieCore

/// Round 22 R22A (owner, 2026-11-06): "when I have aurral connected, all of the playlists (flows) that are within
/// Aurral are kept separate from Magpie Playlists and rather exist in Discover only" (D181–D185).
///
/// Read from Aurral's public source (v2.13.0 `services/playback/navidromePlaybackDestination.ts`, and the playlist
/// files that replaced it after 2.13, `services/playlists/playlistFiles.ts`), and Navidrome's playlist import
/// (`core/playlists/parse_nsp.go`: an imported file's playlist is named after the file).
extension DiscoverRules {
    /// D181: every name (folded) Aurral may give a flow's or a shared playlist's Navidrome playlist:
    /// - the name, and "<owner> - <name>" (Aurral's owner prefix, on by default);
    /// - the older names 2.13 still looks for and renames: "[A] <name>" and "Aurral <name>", "[AS] <name>" and
    ///   "Aurral Shared <name>" (a shared playlist's; both kinds are listed, as Magpie can't always tell them apart);
    /// - each of those as a playlist file's name, which is what Navidrome names an imported playlist: Aurral writes
    ///   `<>:"/\|?*` as "_" and trims (2.13's playlist still waiting for its songs, and every playlist since 2.13).
    static func aurralNames(of flow: AurralFlow) -> [String] {
        let name = normalised(flow.name)
        guard !name.isEmpty else { return [] }
        var names = [name, "[a] " + name, "aurral " + name, "[as] " + name, "aurral shared " + name]
        if let owner = flow.ownerUsername.map(normalised), !owner.isEmpty { names.append(owner + " - " + name) }
        for name in names { names.append(fileName(name)) }
        var seen = Set<String>()
        return names.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Aurral's playlist file name (`sanitizePlaylistFileName`), folded again.
    static func fileName(_ name: String) -> String {
        normalised(String(name.map { "<>:\"/\\|?*".contains($0) ? "_" : $0 }))
    }

    /// A name Aurral numbered because it was taken ("Chill (2)", up to " (999)"), without its number; nil otherwise.
    static func withoutCopyNumber(_ name: String) -> String? {
        guard name.hasSuffix(")"), let open = name.lastIndex(of: "("), open > name.startIndex else { return nil }
        let digits = name[name.index(after: open)..<name.index(before: name.endIndex)]
        guard (1...3).contains(digits.count), digits.allSatisfy(\.isASCIIDigit), let number = Int(digits), number >= 2,
              name[name.index(before: open)] == " " else { return nil }
        let base = String(name[..<name.index(before: open)])
        return base.isEmpty ? nil : base
    }

    /// D182 (supersedes D62's "more than half"): whether a playlist named as one of Aurral's is the owner's own, as far
    /// as this read can tell.
    /// - `false`, Aurral's: one of its songs is one of Aurral's copies (`aurralSongIds`), filed in Aurral's library
    ///   (`aurralLibraries`), or (with Aurral's song list read) the flow's (by its jobs: recording id, else artist +
    ///   title with the durations within 3 s).
    /// - `true`, the owner's own (proof): its songs were read and there are some, Aurral's song list was read this
    ///   time and holds songs for this flow (another user's flow has none: never proven), no run is under way (a run
    ///   clears it while the server still holds the last run's songs), what Aurral's
    ///   copies are is known at all (`aurralSongIds` or `aurralLibraries` not empty), and none of its songs is Aurral's.
    /// - `nil`, can't tell (empty, songs or jobs unread, a run, nothing learnt yet): the caller keeps what it knew,
    ///   and a playlist never told apart is Aurral's (a flow just made, or still downloading).
    public static func isOwnersOwn(songs: [Song]?, flowJobs: [AurralJob], jobsRead: Bool, runActive: Bool,
                                   aurralSongIds: Set<String>, aurralLibraries: Set<Int>) -> Bool? {
        guard let songs, !songs.isEmpty else { return nil }
        let aurrals = songs.contains { song in
            aurralSongIds.contains(song.id) || song.libraryId.map(aurralLibraries.contains) == true
                || (jobsRead && isFlowSong(song, jobs: flowJobs))
        }
        if aurrals { return false }
        guard jobsRead, !flowJobs.isEmpty, !runActive, !aurralSongIds.isEmpty || !aurralLibraries.isEmpty
        else { return nil }
        return true
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
