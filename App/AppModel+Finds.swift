import Foundation
import LidarrKit
import MagpieCore
import NavidromeKit
import Observation
import Requests

/// Finds-mode setup (Task 6.1): local state only, nothing is written to Lidarr (G5). Finds-mode Try, the Finds
/// shelf and the no-scrobble rule for finds (Task 6.2a, D29).
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
        let played = Set(appDefaults.stringArray(forKey: Self.playedFindsKey(navidromeScope)) ?? [])
        if played != playedFinds { playedFinds = played }
        syncFindsIdentity()   // the account may have changed even when the setup didn't
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
    /// differ). The mapping is a mount prefix: the main root new music goes to must map too, and the library
    /// must neither equal, hold nor sit inside it, any other mapped Lidarr root, or any other Navidrome library.
    func chooseFindsLibrary(_ library: NavidromeLibrary, among all: [NavidromeLibrary],
                            mapping: PathMapping?) throws(FindsProblem) {
        guard var setup = findsSetup, let root = setup.findsRoot else { throw .notConnected }
        guard let main = lidarrSetup?.rootFolderPath else { throw .mainRootFirst }
        let toNavidrome: (String) -> String? = { path in mapping.map { $0.toNavidrome(path) } ?? PathGuard.standardize(path) }
        guard let mapped = toNavidrome(root), mapped == PathGuard.standardize(library.path) else {
            throw mapping == nil ? .pathsDiffer : .mappingMismatch
        }
        guard let mappedMain = toNavidrome(main) else { throw .mainRootNotMapped }
        let otherRoots = (lidarrStatus?.roots.map(\.path) ?? []).filter { $0 != root }.compactMap(toNavidrome)
        let others = [mappedMain] + otherRoots + all.filter { $0.id != library.id }.map(\.path)
        guard PathGuard.validateRoot(mapped, others: others) == .ok else { throw .overlapsLibrary }
        setup.library = library
        setup.mapping = mapping
        saveFinds(setup)
        Task { await refreshFinds() }
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

    // MARK: - Finds-mode Try (Task 6.2a)

    /// What the runner adds with: fallback mode, plus Finds mode only when "Use a Finds folder" is on, the
    /// Finds setup is complete for this Lidarr and Navidrome account, and both tags are known. The runner
    /// checks the Finds root again against fresh root folders before each add (G2).
    var runnerSetup: RequestRunner.Setup? {
        guard var setup = lidarrSetup?.runnerSetup else { return nil }
        if let finds = findsSetup, finds.isComplete, let root = finds.findsRoot,
           let magpie = lidarrSetup?.magpieTagId, let find = lidarrSetup?.findTagId,
           !Self.sameFolder(root, setup.rootFolderPath) {
            setup.finds = RequestRunner.Setup.Finds(rootFolderPath: root, tagIds: [magpie, find])
        }
        return setup
    }

    /// Try sends new artists into the Finds folder.
    var triesGoIntoFinds: Bool { runnerSetup?.finds != nil }

    /// Where "Use a Finds folder" stands, for Settings.
    var findsStatus: FindsStatus {
        guard let finds = findsSetup, finds.useFindsFolder else { return .off }
        guard finds.isComplete else { return .notFinished }
        return lidarrSetup?.findTagId == nil ? .needsSetUpAgain : .on
    }

    /// Where Try says the song goes (B8: honest about fallback).
    var tryNote: String { triesGoIntoFinds ? TryCopy.findsNote : TryCopy.fallbackNote }

    // MARK: - Finds shelf (Task 6.2a)

    nonisolated static let playedFindsKeyPrefix = "magpie.findsPlayed."
    nonisolated static func playedFindsKey(_ navidromeScope: String) -> String { playedFindsKeyPrefix + navidromeScope }
    nonisolated static let findSongIdsKeyPrefix = "magpie.findsSongs."
    /// The Finds library's song ids as last read, per Navidrome account and library (D29 on a cold start).
    nonisolated static func findSongIdsKey(_ navidromeScope: String, libraryId: Int) -> String {
        "\(findSongIdsKeyPrefix)\(navidromeScope).\(libraryId)"
    }

    /// The shelf now: the Finds library's songs, finds on their way, New finds.
    func findsShelf(now: Date = Date()) -> FindsShelf {
        FindsShelf(songs: findSongs, requests: requests, played: playedFinds, now: now)
    }

    /// Reads the Finds library's songs again. A failure keeps what was read before.
    func refreshFinds() async {
        guard let library = findsSetup?.library else {
            if !findSongs.isEmpty { findSongs = [] }
            return
        }
        do {
            let songs = try await request { try await $0.songs(inLibrary: library.id) }
            guard findsSetup?.library?.id == library.id, let scope = navidromeScope else { return }   // changed meanwhile
            let key = Self.findSongIdsKey(scope, libraryId: library.id)
            let ids = Set(songs.map(\.id))
            appDefaults.set(Array(ids).sorted(), forKey: key)
            findIdsCache = (key, ids)
            findSongs = songs
        } catch {
            Log.logger("finds").error("finds not read: \(Log.category(of: error), privacy: .public)")
        }
    }

    /// D29: the song is in the Finds library (never scrobbled).
    func isFind(_ song: Song) -> Bool { findsIdentity.isFind(song) }

    /// The Finds library counts whenever one is chosen, even with "Use a Finds folder" off: what's already in
    /// it is still a find. Its song ids come from the last read, saved per account and library; until there
    /// is one, the identity fails closed (`FindsIdentity`).
    func syncFindsIdentity() {
        guard let libraryId = findsSetup?.library?.id, let scope = navidromeScope else {
            findIdsCache = nil
            findsIdentity.set(libraryId: findsSetup?.library?.id, songIds: nil)
            return
        }
        let key = Self.findSongIdsKey(scope, libraryId: libraryId)
        if findIdsCache?.key != key {
            findIdsCache = (key, appDefaults.stringArray(forKey: key).map { Set($0) })
        }
        findsIdentity.set(libraryId: libraryId, songIds: findIdsCache?.ids)
    }

    /// A find that starts playing is no longer new (saved per Navidrome account).
    func watchFindPlays() {
        findPlaysWatch = Task { [weak self, player] in
            let current = Observations { @MainActor in player.queue.current?.song }
            for await song in current {
                guard let self else { return }
                guard let song, self.isFind(song), let scope = self.navidromeScope,
                      !self.playedFinds.contains(song.id) else { continue }
                self.playedFinds.insert(song.id)
                self.appDefaults.set(Array(self.playedFinds), forKey: Self.playedFindsKey(scope))
            }
        }
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
