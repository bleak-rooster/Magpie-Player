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

    /// The library picked from Lidarr's root for this account, if any (cleared when the owner chooses one). Only
    /// this pick is saved; the "most albums" guess never is (N1).
    var autoMainLibraryId: Int? {
        navidromeScope.flatMap { appDefaults.object(forKey: Self.autoMainLibraryKey($0)) as? Int }
    }

    /// How the main library was set.
    enum MainLibraryPick: Equatable {
        /// The owner chose it in Settings (or R18 picked the only other library).
        case chosen
        /// The library holding Lidarr's main root folder.
        case lidarrRoot
        /// A guess: the library with the most albums (no Lidarr root yet); kept in memory only.
        case mostAlbums
        /// The only library besides the separate ones.
        case obvious
        /// None: every library is read.
        case none
    }

    var mainLibraryPick: MainLibraryPick {
        guard let main = mainLibraryId else { return .none }
        let auto = autoMainLibraryId
        if let chosen = findsSetup?.mainLibrary?.id, chosen == main { return chosen == auto ? .lidarrRoot : .chosen }
        if auto == main { return .lidarrRoot }
        if fallbackMainLibraryId == main { return .mostAlbums }
        return .obvious
    }

    /// The main library came from an automatic pick, not the owner's choice (Settings says so).
    var mainLibraryPickedAutomatically: Bool { [.lidarrRoot, .mostAlbums].contains(mainLibraryPick) }

    /// The library the lists read, or nil for all of them.
    var mainLibraryId: Int? {
        Self.mainLibraryId(chosen: findsSetup?.mainLibrary?.id ?? autoMainLibraryId ?? fallbackMainLibraryId,
                           folders: knownMusicFolderIds, separate: separateLibraryIds)
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
        if session != nil, matchIndex != nil {   // m4: what counts as yours follows the scope
            Task { [weak self] in try? await self?.refreshMatchIndex() }
        }
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

    /// N1: Lidarr's root, the Finds setup or the Finds library arrived or changed: pick again.
    func mainLibraryInputsChanged() {
        guard session != nil else { return }
        Task { [weak self] in await self?.autoPickMainLibrary() }
    }

    /// The Finds library became known (FM2): it is kept out of the lists, and the pick is redone without it.
    func findsLibraryLearned() {
        syncLibraryScope()
        mainLibraryInputsChanged()
    }

    /// Picks the main library when the owner hasn't (fix rounds 1 and 2):
    /// - with Lidarr's main root: the library holding it (saved, shown in Settings); none when it's in no library;
    /// - with Lidarr connected but no root yet: no pick (Lidarr will decide);
    /// - without Lidarr: the library with the most albums, never a separate one (Finds), kept in memory only.
    /// Runs again whenever Lidarr's root, the Finds setup or the Finds library changes; a later Lidarr pick replaces a
    /// guess or an earlier automatic pick, never the owner's choice.
    func autoPickMainLibrary() async {
        guard let scope = navidromeScope, let folders = knownMusicFolderIds else { return }
        let auto = autoMainLibraryId
        if let chosen = findsSetup?.mainLibrary?.id, chosen != auto { return }   // the owner's choice stands
        let separate = separateLibraryIds
        let candidates = folders.filter { !separate.contains($0) }
        guard candidates.count > 1 else {   // obvious (or one library): nothing to pick
            fallbackMainLibraryId = nil
            return syncLibraryScope()
        }
        var lidarrPick: NavidromeLibrary?, guess: Int?
        if let root = lidarrSetup?.rootFolderPath {
            if let libraries = (try? await navidromeLibraries())?.filter({ candidates.contains($0.id) }) {
                lidarrPick = Self.libraryHolding(root: root, mapping: findsSetup?.mapping, libraries: libraries)
            }
        } else if lidarr == nil {
            let counts = await withTaskGroup(of: (Int, Int?).self) { group in
                for id in candidates {
                    group.addTask { [weak self] in (id, try? await self?.request { try await $0.albumCount(inLibrary: id) }) }
                }
                var counts: [(id: Int, albums: Int)] = []
                for await (id, n) in group { if let n { counts.append((id, n)) } }
                return counts
            }
            if let most = counts.map(\.albums).max(), counts.filter({ $0.albums == most }).count == 1 {
                guess = counts.first { $0.albums == most }?.id
            }
        }
        guard navidromeScope == scope else { return }
        if let chosen = findsSetup?.mainLibrary?.id, chosen != autoMainLibraryId { return }   // chosen meanwhile
        fallbackMainLibraryId = guess.flatMap { separateLibraryIds.contains($0) ? nil : $0 }
        if let lidarrPick {
            appDefaults.set(lidarrPick.id, forKey: Self.autoMainLibraryKey(scope))
            if var setup = findsSetup, setup.library?.id != lidarrPick.id, setup.mainLibrary != lidarrPick {
                setup.mainLibrary = lidarrPick
                findsSetup = setup
                findsStore.save(setup)
            }
        } else if auto != nil {   // the root moved out of every library, or Lidarr went: the old pick goes too
            appDefaults.removeObject(forKey: Self.autoMainLibraryKey(scope))
            if var setup = findsSetup, setup.mainLibrary?.id == auto {
                setup.mainLibrary = nil
                findsSetup = setup
                findsStore.save(setup)
            }
        }
        syncLibraryScope()
    }

    nonisolated static let musicFoldersKeyPrefix = "magpie.musicFolders."
    nonisolated static func musicFoldersKey(_ navidromeScope: String) -> String { musicFoldersKeyPrefix + navidromeScope }
    nonisolated static let autoMainLibraryKeyPrefix = "magpie.autoMainLibrary."
    nonisolated static func autoMainLibraryKey(_ navidromeScope: String) -> String { autoMainLibraryKeyPrefix + navidromeScope }
}
