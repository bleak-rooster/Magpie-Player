import AurralKit
import Foundation
import MagpieCore
import NavidromeKit

/// One Discover playlist as its page shows it: the playlist, its flow (when Aurral named it), and its songs with the
/// main library's copies in place.
struct DiscoverPage: Equatable {
    var playlist: Playlist
    var flow: AurralFlow?
    var entries: [DiscoverEntry]

    var songs: [Song] { entries.map(\.song) }
}

/// Round 12 Y6 (plan item 7): Aurral's flows as Discover.
///
/// - Aurral is asked only through `AurralClient`'s five calls; nothing is ever written to Aurral except Refresh Flow on
///   the owner's confirmed tap, refused while a run is active.
/// - Discover is the Navidrome playlists named after Aurral's flows; they are kept out of Playlists (Home, Library,
///   the car, Add to playlist), and no playlist edit is ever sent to one.
/// - Aurral's library (found from its job paths) is kept out of Home, Library, Search and the car (Y3's scope).
/// - Swap in Magpie, never in Aurral's data: a flow song the main library also has (by MusicBrainz recording id, else
///   artist + title + duration within 3 s, never by name alone) shows and plays as the library's copy, in place.
/// Offline nothing is asked of Aurral (or of the server).
extension AppModel {
    // MARK: - Connection

    /// Aurral is set up (an address and key are saved). Discover shows only then.
    var aurralSetUp: Bool { discover.connection != nil }

    /// The saved Aurral is plain http to a public host without consent (a reinstall): nothing is sent to it until the
    /// owner allows it in Settings.
    var aurralAwaitingConsent: Bool {
        _ = plainHTTPConsentRevision
        return discover.connection.map { !plainHTTPConsent.allows($0.base) } ?? false
    }

    /// A client for the saved Aurral; nil without one, or while its address waits for consent (the key is never sent
    /// unencrypted to a public address without the owner's say-so).
    var aurralClient: AurralClient? {
        guard let connection = discover.connection, plainHTTPConsent.allows(connection.base) else { return nil }
        return AurralClient(base: connection.base, apiKey: connection.apiKey, transport: transport)
    }

    /// Checks the address (`/api/health`) and key (`/api/playlists/status`), then saves both to the Keychain. Throws
    /// `PlainHTTPConsentRequired` for a public plain-http address the owner hasn't allowed (nothing sent), the ATS
    /// error, `AurralError.unauthorized` for a wrong key, `AurralError.notFound` for something that isn't Aurral.
    func connectAurral(base: URL, apiKey: String) async throws -> AurralHealth {
        if atsBlocks(base) { throw Self.atsError(base) }
        guard plainHTTPConsent.allows(base) else { throw PlainHTTPConsentRequired(urls: [base]) }
        let connection = AurralConnection(base: base, apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
        let client = AurralClient(base: connection.base, apiKey: connection.apiKey, transport: transport)
        let health = try await client.health()
        let status = try await client.status()
        try discover.store.save(connection)
        if discover.connection != connection { forgetDiscoverReads() }
        discover.connection = connection
        discover.health = health
        discover.status = status
        discover.statusReadAt = .now
        await refreshDiscover(force: true)
        return health
    }

    /// Settings › Aurral's "Test connection": the version, and whether the key still works.
    func testAurral() async throws -> AurralHealth {
        guard let client = aurralClient else { throw AurralError.unauthorized }
        let health = try await client.health()
        discover.health = health
        let status = try await client.status()
        discover.status = status
        discover.statusReadAt = .now
        return health
    }

    /// The owner allowed the saved Aurral's plain-http address.
    func allowAurralAddress() {
        guard let base = discover.connection?.base else { return }
        allowPlainHTTP([base])
    }

    /// Forgets the address and key on this iPhone (nothing in Aurral changes); Discover goes, and Aurral's library is
    /// listed again as any other library would be.
    func disconnectAurral() {
        discover.store.clear()
        discover.connection = nil
        forgetDiscoverReads()
    }

    /// Sign-out: the Aurral connection goes with the account.
    func forgetDiscover() {
        disconnectAurral()
    }

    private func forgetDiscoverReads() {
        discover.forgetReads()
        if let scope = navidromeScope {
            appDefaults.removeObject(forKey: Self.discoverPlaylistsKey(scope))
            appDefaults.removeObject(forKey: Self.discoverLibrariesKey(scope))
        }
        syncLibraryScope()
    }

    // MARK: - Which playlists and library are Discover's

    /// The Discover playlists' ids: as last matched, else as saved for this account (so they're kept out of Playlists
    /// before Aurral answers). None unless Aurral is set up.
    var discoverPlaylistIds: Set<String> {
        guard aurralSetUp else { return [] }
        if !discover.playlists.isEmpty { return Set(discover.playlists.map(\.playlist.id)) }
        guard let scope = navidromeScope else { return [] }
        return Set(appDefaults.stringArray(forKey: Self.discoverPlaylistsKey(scope)) ?? [])
    }

    func isDiscoverPlaylist(id: String) -> Bool { discoverPlaylistIds.contains(id) }

    /// The libraries holding Aurral's flow files, as learnt from its job paths (`DiscoverRules.discoverLibraries`).
    var savedDiscoverLibraryIds: Set<Int> {
        guard aurralSetUp, let scope = navidromeScope else { return [] }
        return Set(appDefaults.array(forKey: Self.discoverLibrariesKey(scope)) as? [Int] ?? [])
    }

    // MARK: - Reading Aurral

    /// Reads Aurral's flows and matches them to the server's playlists (and its jobs, for the songs' ids). At most
    /// every 30 s unless `force`. Offline, or without Aurral, nothing is asked. A failure keeps what was read before.
    func refreshDiscover(force: Bool = false) async {
        guard let client = aurralClient, session != nil, !isOffline, let scope = navidromeScope else { return }
        if !force, let at = discover.statusReadAt, Date.now.timeIntervalSince(at) < 30, !discover.playlists.isEmpty { return }
        let connection = discover.connection
        guard let status = try? await client.status(),
              let all = try? await request({ try await $0.playlists() }) else { return }
        let jobs = (try? await client.jobs()) ?? nil
        guard navidromeScope == scope, discover.connection == connection else { return }   // another account or Aurral
        discover.status = status
        discover.statusReadAt = .now
        if let jobs { discover.jobs = jobs }
        for flowId in discover.refreshing where status.isRunActive(flowId: flowId) { discover.refreshing.remove(flowId) }
        let matched = DiscoverRules.flowPlaylists(flows: status.flows, playlists: all)
        let changed = Set(matched.map(\.playlist.id)) != discoverPlaylistIds
        discover.playlists = matched
        appDefaults.set(matched.map(\.playlist.id), forKey: Self.discoverPlaylistsKey(scope))
        if changed { libraryEdits.playlistsRevision += 1 }   // Playlists lists read again without them
    }

    /// Discover's playlists for Home, Library and the car: read again when stale; if Aurral doesn't answer, the
    /// server's playlists that were Discover's last time.
    func discoverPlaylists() async throws -> [Playlist] {
        guard aurralSetUp, !isOffline else { return [] }
        await refreshDiscover()
        if !discover.playlists.isEmpty { return discover.playlists.map(\.playlist) }
        let ids = discoverPlaylistIds
        guard !ids.isEmpty else { return [] }
        return try await request { try await $0.playlists() }.filter { ids.contains($0.id) }
    }

    /// The flow a Discover playlist belongs to, if known.
    func discoverFlow(playlistId: String) -> AurralFlow? {
        discover.playlists.first { $0.playlist.id == playlistId }?.flow
    }

    // MARK: - A Discover playlist's page

    /// The playlist with each flow song the main library has shown as the library's copy, in its place (copies already
    /// known show at once; `fresh` looks them all up again).
    func discoverPage(playlistId: String) async throws -> DiscoverPage {
        let (playlist, songs) = try await request { try await $0.playlist(id: playlistId) }
        noteFlowSongs(songs)
        let flow = discoverFlow(playlistId: playlistId)
        let copies = await libraryCopies(for: songs, flowId: flow?.id)
        return DiscoverPage(playlist: playlist, flow: flow, entries: DiscoverRules.swapped(songs, copies: copies))
    }

    /// The flow songs as Aurral's copies: never a "library copy" of anything, and an artist page hides an album of
    /// them whose every song has a library copy.
    func noteFlowSongs(_ songs: [Song]) {
        discover.flowSongIds.formUnion(songs.map(\.id))
        for song in songs {
            if let album = song.albumId { discover.flowAlbumSongs[album, default: []].insert(song.id) }
        }
    }

    /// The main library's copy of each of `songs` that has one (by the song's id). Looks each song up: by recording id
    /// (the song's, else Aurral's job's) through the server's lookup, which also says which library each copy is in
    /// (and so where Aurral's files are: `learnDiscoverLibrary`); else by title, matched on artist + title + duration.
    func libraryCopies(for songs: [Song], flowId: String?) async -> [String: Song] {
        guard session != nil, !isOffline, !songs.isEmpty else { return [:] }
        let jobs = discover.jobs
        let excluding = discover.flowSongIds.union(songs.map(\.id)).union(findSongs.map(\.id))
        let libraries = listedLibraryIds.map(Set.init)
        let notLibraries = separateLibraryIds
        var copies: [String: Song] = [:]
        var rows: [String: [Song]] = [:]
        await withTaskGroup(of: (String, Song?, [Song]).self) { group in
            var started = 0
            for song in songs {
                if started >= 4, let done = await group.next() {   // four at a time
                    copies[done.0] = done.1
                    rows[done.0] = done.2
                }
                started += 1
                let recording = song.recordingMBID ?? Self.jobRecording(for: song, jobs: jobs, flowId: flowId)
                group.addTask { [weak self] in
                    guard let self else { return (song.id, nil, []) }
                    let (copy, found) = await self.libraryCopy(of: song, recording: recording, excluding: excluding,
                                                               libraries: libraries, notLibraries: notLibraries)
                    return (song.id, copy, found)
                }
            }
            for await done in group {
                copies[done.0] = done.1
                rows[done.0] = done.2
            }
        }
        let found = copies.compactMapValues { $0 }
        for song in songs { discover.copies[song.id] = found[song.id] }
        learnDiscoverLibrary(entries: songs, rows: rows)
        return found
    }

    /// Aurral's job's recording id for a flow song without one: the job of the same artist and title in the flow.
    nonisolated static func jobRecording(for song: Song, jobs: [AurralJob], flowId: String?) -> MBID? {
        let artist = DiscoverRules.normalised(song.artist), title = DiscoverRules.normalised(song.title)
        return jobs.first {
            (flowId == nil || $0.flowId == flowId) && DiscoverRules.normalised($0.artistName) == artist
                && DiscoverRules.normalised($0.trackName) == title
        }?.trackMBID
    }

    private func libraryCopy(of song: Song, recording: MBID?, excluding: Set<String>, libraries: Set<Int>?,
                             notLibraries: Set<Int>) async -> (Song?, [Song]) {
        var rows: [Song] = []
        if let recording {
            rows = (try? await request { try await $0.songs(recordingMBID: recording, excludingLibrary: nil) }) ?? []
            if let copy = DiscoverRules.mainCopy(for: song, recording: recording, mbidMatches: rows, textMatches: [],
                                                 excluding: excluding, libraries: libraries, notLibraries: notLibraries) {
                return (copy, rows)
            }
        }
        guard song.duration > 0, !song.title.isEmpty else { return (nil, rows) }
        let hits = (try? await request { [title = song.title] in
            try await $0.search(title, songCount: 20, albumCount: 0, artistCount: 0)
        })?.songs ?? []
        let copy = DiscoverRules.mainCopy(for: song, recording: nil, mbidMatches: [], textMatches: hits,
                                          excluding: excluding, libraries: libraries, notLibraries: notLibraries)
        return (copy, rows)
    }

    /// Learns the library Aurral's flow files are in from its job paths (`DiscoverRules.discoverLibraries`): never the
    /// main library, a library holding a Lidarr root, or the only library; then the lists leave it out (Y3's scope).
    func learnDiscoverLibrary(entries: [Song], rows: [String: [Song]]) {
        guard let scope = navidromeScope, let folders = knownMusicFolderIds, folders.count > 1 else { return }
        var listed = Set(listedLibraryIds ?? [])
        listed.formUnion(lidarrLibraryIds)
        if let main = mainLibraryId { listed.insert(main) }
        if let chosen = findsSetup?.mainLibrary?.id { listed.insert(chosen) }
        let found = DiscoverRules.discoverLibraries(entries: entries, rows: rows, jobs: discover.jobs, listed: listed)
            .filter { folders.contains($0) && $0 != findsLibraryId }
        let known = savedDiscoverLibraryIds
        guard !found.isEmpty, !found.isSubset(of: known), found.count + known.count < folders.count else { return }
        appDefaults.set(Array(known.union(found)).sorted(), forKey: Self.discoverLibrariesKey(scope))
        syncLibraryScope()
        mainLibraryInputsChanged()
    }

    // MARK: - Refresh Flow

    /// Refresh Flow (after the owner confirmed "Replaces this playlist's songs"): read Aurral's status fresh and refuse
    /// while a run is under way (`AurralError.runActive`, nothing sent); otherwise start the flow's run.
    func refreshFlow(_ flowId: String) async throws {
        guard !isOffline else { throw Self.forcedOfflineError }
        guard let client = aurralClient else { throw AurralError.unauthorized }
        let status = try await client.status()
        discover.status = status
        discover.statusReadAt = .now
        guard !status.isRunActive(flowId: flowId), !discover.refreshing.contains(flowId) else { throw AurralError.runActive }
        discover.refreshing.insert(flowId)
        do {
            _ = try await client.startFlow(flowId)
        } catch {
            discover.refreshing.remove(flowId)
            throw error
        }
        if let fresh = try? await client.status() {
            discover.status = fresh
            discover.statusReadAt = .now
        }
    }

    /// Reads the worker's progress again (the page polls while a run is under way). A run Magpie started stays "under
    /// way" until Aurral's status shows it, then follows Aurral.
    func refreshDiscoverStatus() async {
        guard let client = aurralClient, !isOffline, let status = try? await client.status() else { return }
        discover.status = status
        discover.statusReadAt = .now
        for flowId in discover.refreshing where status.isRunActive(flowId: flowId) { discover.refreshing.remove(flowId) }
    }

    /// Whether the flow's run is under way (Refresh Flow is then refused).
    func isFlowRunActive(_ flowId: String) -> Bool {
        discover.refreshing.contains(flowId) || (discover.status?.isRunActive(flowId: flowId) ?? false)
    }

    // MARK: - Artists

    /// The artists of a Discover playlist (Aurral's jobs give their MusicBrainz ids).
    func discoverArtists(_ page: DiscoverPage) -> [DiscoverArtist] {
        DiscoverRules.artists(entries: page.entries.filter { !$0.inYourLibrary }.map(\.original), jobs: discover.jobs,
                              flowId: page.flow?.id)
    }

    /// A flow song's artist, for "Add <artist> to your library".
    func discoverArtist(for song: Song, flowId: String?) -> DiscoverArtist {
        DiscoverArtist(name: song.artist, mbid: DiscoverRules.artistMBID(for: song, jobs: discover.jobs, flowId: flowId))
    }

    // MARK: - Elsewhere: hiding Aurral's copy where it would duplicate

    /// An artist page's albums without those made only of Aurral copies the library has its own copy of.
    func hidingFlowDuplicates(_ albums: [Album]) -> [Album] {
        guard aurralSetUp else { return albums }
        return albums.filter { album in
            guard let ids = discover.flowAlbumSongs[album.id], !ids.isEmpty else { return true }
            return !ids.allSatisfy { discover.copies[$0] != nil }
        }
    }

    /// Songs with each Aurral copy the library has its own copy of replaced by that copy, in place (an Aurral album's
    /// page, a Discover playlist the car opens).
    func swappingFlowCopies(_ songs: [Song]) -> [Song] {
        guard aurralSetUp else { return songs }
        return songs.map { discover.copies[$0.id] ?? $0 }
    }

    // MARK: - Keys

    nonisolated static let discoverPlaylistsKeyPrefix = "magpie.discoverPlaylists."
    nonisolated static func discoverPlaylistsKey(_ scope: String) -> String { discoverPlaylistsKeyPrefix + scope }
    nonisolated static let discoverLibrariesKeyPrefix = "magpie.discoverLibraries."
    nonisolated static func discoverLibrariesKey(_ scope: String) -> String { discoverLibrariesKeyPrefix + scope }
}

/// Discover's words (§5 voice; the glossary's "your library").
enum DiscoverCopy {
    static let title = "Discover"
    static let refresh = "Refresh Flow"
    static let refreshConfirm = "Replaces this playlist\u{2019}s songs"
    static let refreshing = "Getting new songs\u{2026}"
    static let runActive = "A refresh is already under way. Try again when it\u{2019}s done."
    static let inYourLibrary = "In your library"
    static let artistsInPlaylist = "Artists in this playlist"
    static let empty = "No Discover playlists yet."
    static func progress(_ p: AurralProgress) -> String { "Getting songs: \(p.done) of \(p.total)" }
    static func addArtist(_ name: String) -> String { "Add \(name) to your library" }
    static let useLibraryCopy = "Use your library\u{2019}s copy"
    static func libraryCopies(_ n: Int) -> String {
        n == 1 ? "1 song here is a Discover copy of a song in your library."
               : "\(n) songs here are Discover copies of songs in your library."
    }
    static func usedLibraryCopies(_ n: Int) -> String {
        n == 1 ? "Now plays your library\u{2019}s copy" : "Now plays your library\u{2019}s copies"
    }
    static let tooLong = "This playlist is too long to change in one go."

    static func message(for error: Error) -> String {
        switch error as? AurralError {
        case .runActive?: runActive
        case .unauthorized?: "Discover\u{2019}s server refused the key. Check it in Settings \u{203A} New music."
        case .notFound?: "That flow isn\u{2019}t there any more."
        case .forbidden?: "Magpie doesn\u{2019}t send that."
        default: AppModel.isConnectionError(error) ? "Discover\u{2019}s server isn\u{2019}t answering right now." : BrowseErrorCopy.message(for: error)
        }
    }
}
