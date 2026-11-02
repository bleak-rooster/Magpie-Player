import Foundation
import LidarrKit
import NavidromeKit

/// Round 12 Y3 (plan item 5): Home, Library, Search and CarPlay read the **main library** only, so Aurral's flow
/// downloads and the Finds folder never turn up as "random albums". The main library is:
/// 1. the one chosen in R18 ("Main library", Settings);
/// 2. else the one obvious from the folders: exactly one library besides the ones kept apart (Finds; Discover's, Y6);
/// 3. else picked automatically (fix round 1), never by a library's name:
///    - the Navidrome library holding Lidarr's main root folder (through the Finds path mapping, `keptLocation`);
///    - without a Lidarr main root, the library with the most albums, Finds left out.
///    The pick is saved where Settings shows it (`findsSetup.mainLibrary`, or per account without a Finds setup);
///    the owner can change it there.
/// With one library, or no pick, no library is named and the server answers for all of them, as before. Album artists
/// only (R11) is untouched: it filters artists, not libraries.
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

    /// Y6 hook: the Aurral library ("Aurral Playlists"), shown only under Discover, found from Aurral's job paths
    /// (never from its name). None until Aurral is set up.
    var discoverLibraryIds: Set<Int> { [] }

    /// The library picked automatically for this account, if any (cleared when the owner chooses one).
    var autoMainLibraryId: Int? {
        navidromeScope.flatMap { appDefaults.object(forKey: Self.autoMainLibraryKey($0)) as? Int }
    }

    /// The main library came from the automatic pick, not the owner's choice (Settings can say so).
    var mainLibraryPickedAutomatically: Bool {
        guard let auto = autoMainLibraryId, auto == mainLibraryId else { return false }
        return findsSetup?.mainLibrary.map { $0.id == auto } ?? true
    }

    /// The library the lists read, or nil for all of them.
    var mainLibraryId: Int? {
        Self.mainLibraryId(chosen: findsSetup?.mainLibrary?.id ?? autoMainLibraryId, folders: knownMusicFolderIds,
                           separate: separateLibraryIds)
    }

    /// The match index (what counts as already yours for outside results) covers the main library and Finds, named
    /// explicitly, never Discover's; every library while no main library is known.
    var matchIndexLibraries: NavidromeClient.LibraryFilter {
        guard let main = mainLibraryId else { return .all }
        return .only([main] + [findsLibraryId].compactMap { $0 }.filter { $0 != main })
    }

    /// The chosen main library (unless it's one kept apart, or the server no longer lists it); otherwise the one
    /// library left once the separate ones are set aside. Nil with a single library (nothing to keep apart) or when
    /// more than one is left (picked by `autoPickMainLibrary`).
    nonisolated static func mainLibraryId(chosen: Int?, folders: [Int]?, separate: Set<Int>) -> Int? {
        if let chosen, !separate.contains(chosen), folders?.contains(chosen) ?? true {
            return (folders?.count ?? 2) > 1 ? chosen : nil
        }
        guard let folders, folders.count > 1 else { return nil }
        let left = folders.filter { !separate.contains($0) }
        return left.count == 1 ? left[0] : nil
    }

    /// The one library holding Lidarr's main root folder `root`, through `mapping` (Lidarr → Navidrome paths), among
    /// `libraries`. The root itself, or any folder in it, counts. Nil when none or several hold it.
    nonisolated static func libraryHolding(root: String, mapping: PathMapping?,
                                           libraries: [NavidromeLibrary]) -> NavidromeLibrary? {
        guard let base = PathGuard.standardize(root) else { return nil }
        let none = NavidromeLibrary(id: Int.min, name: "", path: "")
        return keptLocation(base + "/artist", findsLibrary: none, mapping: mapping, libraries: libraries)?.0
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

    /// Reads the server's libraries (best effort: a failure keeps the last list), picks the main library when it
    /// isn't known yet, and scopes the client again. Offline (Task 14) nothing is asked.
    func refreshMusicFolders() async {
        guard !isOffline, let scope = navidromeScope,
              let folders = try? await request({ try await $0.musicFolders() }), navidromeScope == scope else { return }
        appDefaults.set(folders.map(\.id), forKey: Self.musicFoldersKey(scope))
        await autoPickMainLibrary()
        syncLibraryScope()
    }

    /// Fix round 1 (I1): picks the main library when it can't be told from the folders alone (more than one library
    /// besides the separate ones, none chosen). Lidarr's main root decides; without one, the most albums do.
    func autoPickMainLibrary() async {
        guard let scope = navidromeScope, let folders = knownMusicFolderIds, mainLibraryId == nil else { return }
        let candidates = folders.filter { !separateLibraryIds.contains($0) }
        guard candidates.count > 1 else { return }
        let libraries = (try? await navidromeLibraries())?.filter { candidates.contains($0.id) }
        var pick: NavidromeLibrary?
        if let root = lidarrSetup?.rootFolderPath {
            if let libraries { pick = Self.libraryHolding(root: root, mapping: findsSetup?.mapping, libraries: libraries) }
        } else {
            var counts: [(id: Int, albums: Int)] = []
            for id in candidates {
                if let n = try? await request({ try await $0.albumCount(inLibrary: id) }) { counts.append((id, n)) }
            }
            let most = counts.map(\.albums).max()
            if let most, counts.filter({ $0.albums == most }).count == 1, let id = counts.first(where: { $0.albums == most })?.id {
                pick = libraries?.first { $0.id == id } ?? NavidromeLibrary(id: id, name: "", path: "")
            }
        }
        guard let pick, navidromeScope == scope, mainLibraryId == nil else { return }
        appDefaults.set(pick.id, forKey: Self.autoMainLibraryKey(scope))
        if var setup = findsSetup, setup.mainLibrary == nil, setup.library?.id != pick.id {
            setup.mainLibrary = pick
            findsSetup = setup
            findsStore.save(setup)
        }
        syncLibraryScope()
    }

    nonisolated static let musicFoldersKeyPrefix = "magpie.musicFolders."
    nonisolated static func musicFoldersKey(_ navidromeScope: String) -> String { musicFoldersKeyPrefix + navidromeScope }
    nonisolated static let autoMainLibraryKeyPrefix = "magpie.autoMainLibrary."
    nonisolated static func autoMainLibraryKey(_ navidromeScope: String) -> String { autoMainLibraryKeyPrefix + navidromeScope }
}
