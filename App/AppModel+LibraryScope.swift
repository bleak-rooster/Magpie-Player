import Foundation
import NavidromeKit

/// Round 12 Y3 (plan item 5): Home, Library, Search and CarPlay read the **main library** only, so Aurral's flow
/// downloads and the Finds folder never turn up as "random albums". The main library is the one chosen in R18
/// ("Main library", Settings), or picked automatically when the choice is obvious: exactly one library besides the
/// ones kept apart (Finds; Discover's, Y6). With one library, or no obvious choice, no library is named and the server
/// answers for all of them, as before. Album artists only (R11) is untouched: it filters artists, not libraries.
///
/// The scope lives on the client (`NavidromeClient.setLibraryScope`), so every list and search call carries it,
/// whichever screen or the car asks. Lookups by id, playlists and the Finds library's own read are never scoped.
extension AppModel {
    /// The library ids the account's server lists (`getMusicFolders`, readable by any account), as last read.
    var knownMusicFolderIds: [Int]? {
        navidromeScope.flatMap { appDefaults.array(forKey: Self.musicFoldersKey($0)) as? [Int] }
    }

    /// Libraries kept out of Home, Library, Search and the car: the Finds library (shown under Finds) and Discover's.
    var separateLibraryIds: Set<Int> {
        Set([findsLibraryId].compactMap { $0 }).union(discoverLibraryIds)
    }

    /// Y6 hook: the Aurral library ("Aurral Playlists"), shown only under Discover. None until Aurral is set up.
    var discoverLibraryIds: Set<Int> { [] }

    /// The library the lists read, or nil for all of them.
    var mainLibraryId: Int? {
        Self.mainLibraryId(chosen: findsSetup?.mainLibrary?.id, folders: knownMusicFolderIds, separate: separateLibraryIds)
    }

    /// The chosen main library (unless it's one kept apart, or the server no longer lists it); otherwise the one
    /// library left once the separate ones are set aside. Nil with a single library (nothing to keep apart) or when
    /// more than one is left (the owner chooses in Settings).
    nonisolated static func mainLibraryId(chosen: Int?, folders: [Int]?, separate: Set<Int>) -> Int? {
        if let chosen, !separate.contains(chosen), folders?.contains(chosen) ?? true {
            return (folders?.count ?? 2) > 1 ? chosen : nil
        }
        guard let folders, folders.count > 1 else { return nil }
        let left = folders.filter { !separate.contains($0) }
        return left.count == 1 ? left[0] : nil
    }

    /// Hands the main library to the client; when it changed, Home reads again (its saved shelves may hold another
    /// library's albums).
    func syncLibraryScope() {
        let id = session == nil ? nil : mainLibraryId
        session?.client.setLibraryScope(id)
        guard id != libraryScope else { return }
        libraryScope = id
        homeFeedSlot?.libraryChanged()
    }

    /// Reads the server's libraries (best effort: a failure keeps the last list) and scopes the client again.
    /// Offline (Task 14) nothing is asked.
    func refreshMusicFolders() async {
        guard !isOffline, let scope = navidromeScope,
              let folders = try? await request({ try await $0.musicFolders() }), navidromeScope == scope else { return }
        appDefaults.set(folders.map(\.id), forKey: Self.musicFoldersKey(scope))
        syncLibraryScope()
    }

    nonisolated static let musicFoldersKeyPrefix = "magpie.musicFolders."
    nonisolated static func musicFoldersKey(_ navidromeScope: String) -> String { musicFoldersKeyPrefix + navidromeScope }
}
