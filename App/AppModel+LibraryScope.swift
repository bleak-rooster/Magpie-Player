import Foundation
import LidarrKit
import NavidromeKit

/// Round 12 Y3 (plan item 5): Home, Library, Search and CarPlay list only the libraries that hold the owner's music,
/// so Aurral's flow downloads and the Finds folder never turn up as "random albums".
///
/// What is listed (`listedLibraryIds`):
/// - the **main library**: chosen in R18 ("Main library", Settings), else the one obvious from the folders (exactly one
///   besides the separate ones), else the library holding Lidarr's main root folder (mapped through the Finds path
///   mapping with `keptLocation`, saved where Settings shows it). Never picked by a library's name, and never guessed;
/// - every other library holding one of Lidarr's root folders (a second music root, such as the dev stack's Samples);
/// - without any of that (no Lidarr yet): every library but the separate ones.
/// The separate ones (Finds; Discover's, Y6) are never listed. With one library, or when everything is listed, no
/// library is named and the server answers for all of them, as before. Album artists only (R11) is untouched.
///
/// Fix round 3 (regression on the dev stack): the "most albums" guess is gone. With two ordinary libraries and no
/// Lidarr, it listed only the bigger one, so the other library's music disappeared from every list.
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

    /// The library picked from Lidarr's root for this account, if any (cleared when the owner chooses one).
    var autoMainLibraryId: Int? {
        navidromeScope.flatMap { appDefaults.object(forKey: Self.autoMainLibraryKey($0)) as? Int }
    }

    /// How the main library was set.
    enum MainLibraryPick: Equatable {
        /// The owner chose it in Settings (or R18 picked the only other library).
        case chosen
        /// The library holding Lidarr's main root folder.
        case lidarrRoot
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
        return .obvious
    }

    /// The main library came from an automatic pick, not the owner's choice (Settings says so).
    var mainLibraryPickedAutomatically: Bool { mainLibraryPick == .lidarrRoot }

    /// The main library (Keep's scans, "Only in your Finds"), or nil when none is known.
    var mainLibraryId: Int? {
        Self.mainLibraryId(chosen: findsSetup?.mainLibrary?.id ?? autoMainLibraryId,
                           folders: knownMusicFolderIds, separate: separateLibraryIds)
    }

    /// The libraries holding one of Lidarr's root folders (other than the Finds root), as last worked out.
    var lidarrLibraryIds: [Int] {
        navidromeScope.flatMap { appDefaults.array(forKey: Self.lidarrLibrariesKey($0)) as? [Int] } ?? []
    }

    /// The libraries Home, Library, Search and the car list, or nil for all of them.
    var listedLibraryIds: [Int]? {
        Self.listedLibraries(main: mainLibraryId, lidarrLibraries: lidarrLibraryIds, folders: knownMusicFolderIds,
                             separate: separateLibraryIds)
    }

    /// The main library and every library holding a Lidarr root; without either, every library. Never a separate
    /// one. Nil (name none) with one library, or when that's every library.
    nonisolated static func listedLibraries(main: Int?, lidarrLibraries: [Int], folders: [Int]?,
                                            separate: Set<Int>) -> [Int]? {
        guard let folders, folders.count > 1 else { return nil }
        let music = Set(main.map { [$0] } ?? []).union(lidarrLibraries)
        let listed = folders.filter { (music.isEmpty || music.contains($0)) && !separate.contains($0) }
        return listed.isEmpty || listed.count == folders.count ? nil : listed
    }

    /// The match index (what counts as already yours for outside results) covers the listed libraries and Finds,
    /// named explicitly, never Discover's; every library while nothing is set apart.
    var matchIndexLibraries: NavidromeClient.LibraryFilter {
        guard let listed = listedLibraryIds else { return .all }
        return .only(listed + [findsLibraryId].compactMap { $0 }.filter { !listed.contains($0) })
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

    /// The one library holding Lidarr's root folder `root`, through `mapping` (Lidarr → Navidrome paths), among
    /// `libraries`. The root itself, or any folder in it, counts. Nil when none or several hold it.
    nonisolated static func libraryHolding(root: String, mapping: PathMapping?,
                                           libraries: [NavidromeLibrary]) -> NavidromeLibrary? {
        guard let base = PathGuard.standardize(root) else { return nil }
        let none = NavidromeLibrary(id: Int.min, name: "", path: "")
        return keptLocation(base + "/artist", findsLibrary: none, mapping: mapping, libraries: libraries)?.0
    }

    /// Hands the listed libraries to the client; when they changed, Home reads again (its saved shelves may hold
    /// another library's albums).
    func syncLibraryScope() {
        let ids = session == nil ? nil : listedLibraryIds
        session?.client.setLibraryScope(ids)
        guard ids != libraryScope else { return }
        libraryScope = ids
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

    /// Works out which libraries hold Lidarr's root folders, and the main library when the owner hasn't chosen one
    /// (fix rounds 1 to 3):
    /// - the main library is the one holding Lidarr's main root (saved, shown in Settings); none when it's in no
    ///   library or there is no Lidarr root yet. Nothing is guessed;
    /// - every library holding any Lidarr root folder (the Finds root aside) is listed too.
    /// Runs again whenever Lidarr's roots, the Finds setup or the Finds library changes; a later pick replaces an
    /// earlier automatic one, never the owner's choice.
    func autoPickMainLibrary() async {
        guard let scope = navidromeScope, let folders = knownMusicFolderIds else { return }
        let separate = separateLibraryIds
        let candidates = folders.filter { !separate.contains($0) }
        let mainRoot = lidarrSetup?.rootFolderPath
        let roots = ([mainRoot].compactMap { $0 } + (lidarrStatus?.roots.map(\.path) ?? []))
            .filter { root in !(findsSetup?.findsRoot.map { Self.sameFolder($0, root) } ?? false) }
        var mainPick: NavidromeLibrary?, holders: [Int] = []
        if candidates.count > 1, !roots.isEmpty,
           let libraries = (try? await navidromeLibraries())?.filter({ candidates.contains($0.id) }) {
            let mapping = findsSetup?.mapping
            mainPick = mainRoot.flatMap { Self.libraryHolding(root: $0, mapping: mapping, libraries: libraries) }
            holders = roots.compactMap { Self.libraryHolding(root: $0, mapping: mapping, libraries: libraries)?.id }
        }
        guard navidromeScope == scope else { return }
        let held = Array(Set(holders)).sorted()
        if held.isEmpty { appDefaults.removeObject(forKey: Self.lidarrLibrariesKey(scope)) }
        else { appDefaults.set(held, forKey: Self.lidarrLibrariesKey(scope)) }
        let auto = autoMainLibraryId
        if let chosen = findsSetup?.mainLibrary?.id, chosen != auto { return syncLibraryScope() }   // the owner's choice stands
        if let mainPick {
            appDefaults.set(mainPick.id, forKey: Self.autoMainLibraryKey(scope))
            if var setup = findsSetup, setup.library?.id != mainPick.id, setup.mainLibrary != mainPick {
                setup.mainLibrary = mainPick
                findsSetup = setup
                findsStore.save(setup)
            }
        } else if auto != nil, candidates.count > 1 {   // the root moved out of every library, or Lidarr went
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
    nonisolated static let lidarrLibrariesKeyPrefix = "magpie.lidarrLibraries."
    nonisolated static func lidarrLibrariesKey(_ navidromeScope: String) -> String { lidarrLibrariesKeyPrefix + navidromeScope }
}
