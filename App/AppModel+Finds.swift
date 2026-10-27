import Foundation
import LidarrKit
import NavidromeKit

/// Finds-mode setup (Task 6.1): local state only, nothing is written to Lidarr (G5). Try doesn't read it yet.
extension AppModel {
    /// The signed-in Navidrome account (`FindsSetupStore.navidromeScope`).
    var navidromeScope: String? {
        session.map { FindsSetupStore.navidromeScope(base: $0.endpoint.bases[0], username: $0.username) }
    }

    /// Reads the Finds setup of the current Lidarr and Navidrome account (nil unless both are there).
    func reloadFindsSetup() {
        guard let lidarrScope, let navidromeScope else {
            if findsSetup != nil { findsSetup = nil }
            return
        }
        let loaded = findsStore.load(lidarrScope: lidarrScope, navidromeScope: navidromeScope)
        if loaded != findsSetup { findsSetup = loaded }
    }

    /// "Use a Finds folder". Turning it off keeps the confirmed folder, so turning it on again needs no redo.
    func setUseFindsFolder(_ on: Bool) {
        guard var setup = findsSetup else { return }
        setup.useFindsFolder = on
        saveFinds(setup)
    }

    /// G2: why `root` can't be the Finds folder, or nil when it can. It must be one of the Lidarr root folders
    /// last read, and is compared with every other one and with the main root new music goes to.
    func findsRootProblem(_ root: String) -> FindsProblem? {
        guard findsSetup != nil, let status = lidarrStatus, status.reachable else { return .notConnected }
        let roots = status.roots.map(\.path)
        guard roots.contains(root) else { return .notARootFolder }
        if let main = lidarrSetup?.rootFolderPath, Self.sameFolder(main, root) { return .isMainRoot }
        let others = roots.filter { $0 != root }   // every other root, by Lidarr's exact path
        switch PathGuard.validateRoot(root, others: others) {
        case .ok: return nil
        case .equalsOther: return .sameAsOther
        case .nested: return .nested
        case .notAbsolute: return .notAbsolute
        }
    }

    /// The owner confirmed `root` ("Use … for Finds?"). The library and mapping are chosen again afterwards.
    func confirmFindsRoot(_ root: String) throws(FindsProblem) {
        if let problem = findsRootProblem(root) { throw problem }
        guard var setup = findsSetup else { throw .notConnected }
        setup.findsRoot = root
        setup.library = nil
        setup.mapping = nil
        saveFinds(setup)
    }

    /// B6 / G2: `library` must be the Finds folder as Navidrome sees it (through `mapping` when the paths
    /// differ) and must neither hold nor sit inside any other Navidrome library (the main library included).
    func chooseFindsLibrary(_ library: NavidromeLibrary, among all: [NavidromeLibrary],
                            mapping: PathMapping?) throws(FindsProblem) {
        guard var setup = findsSetup, let root = setup.findsRoot else { throw .notConnected }
        let mapped = mapping.map { $0.toNavidrome(root) } ?? PathGuard.standardize(root)
        guard let mapped, mapped == PathGuard.standardize(library.path) else {
            throw mapping == nil ? .pathsDiffer : .mappingMismatch
        }
        let others = all.filter { $0.id != library.id }.map(\.path)
        guard PathGuard.validateRoot(mapped, others: others) == .ok else { throw .overlapsLibrary }
        setup.library = library
        setup.mapping = mapping
        saveFinds(setup)
    }

    /// Navidrome's library folders (`/api/library`).
    func navidromeLibraries() async throws -> [NavidromeLibrary] {
        try await request { try await $0.libraries() }
    }

    /// Deletes in Finds can't be undone when Lidarr's recycle bin is unset (G3, D10). Advice only (G5).
    var findsNeedsRecycleBinWarning: Bool { lidarrStatus?.reachable == true && lidarrStatus?.recycleBinSet == false }

    /// The confirmed Finds folder is never also where new music goes.
    func isFindsRoot(_ path: String) -> Bool {
        guard let root = findsSetup?.findsRoot else { return false }
        return Self.sameFolder(root, path)
    }

    private func saveFinds(_ setup: FindsSetup) {
        findsSetup = setup
        findsStore.save(setup)
    }

    /// The same folder after standardising, ignoring case (refusing more is the safe side).
    nonisolated static func sameFolder(_ a: String, _ b: String) -> Bool {
        guard let a = PathGuard.standardize(a), let b = PathGuard.standardize(b) else { return a == b }
        return a.lowercased() == b.lowercased()
    }
}
