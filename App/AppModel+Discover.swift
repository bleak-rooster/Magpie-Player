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
/// - Aurral is asked only through `AurralClient`'s allow-listed calls (`AurralRoute`); nothing is ever written to
///   Aurral except on the owner's tap: Refresh Flow (refused while a run is active) and round 14's Add flow, Not for me,
///   Download songs and Retry a song.
/// - Discover is the Navidrome playlists named after Aurral's flows; they are kept out of Playlists (Home, Library,
///   the car, Add to playlist), and no playlist edit is ever sent to one.
/// - Aurral's library (found from its job paths) is kept out of Home, Library, Search and the car (Y3's scope).
/// - Swap in Magpie, never in Aurral's data: a flow song the main library also has (by MusicBrainz recording id, else
///   artist + title + duration within 3 s, never by name alone) shows and plays as the library's copy, in place.
/// Offline nothing is asked of Aurral (or of the server).
extension AppModel {
    // MARK: - Connection

    /// Aurral is set up (signed in: an address, a user and a session are saved). Discover shows only then.
    var aurralSetUp: Bool { discover.connection != nil }

    /// The saved Aurral is plain http to a public host without consent (a reinstall): nothing is sent to it until the
    /// owner allows it in Settings.
    var aurralAwaitingConsent: Bool {
        _ = plainHTTPConsentRevision
        return discover.connection.map { !aurralAllows($0.base) } ?? false
    }

    /// Z1 fix M1: consent is per secret. The Aurral password (and its session) go over plain http to a public address
    /// only with the owner's OK for that address *and* for the Aurral password: a round-12 OK (given for the API key)
    /// or another service's doesn't count.
    var aurralPasswordConsent: PlainHTTPConsent {
        PlainHTTPConsent(defaults: appDefaults, key: "magpie.plainHTTPConsent.aurralPassword")
    }

    func aurralAllows(_ url: URL) -> Bool { plainHTTPConsent.allows(url) && aurralPasswordConsent.allows(url) }

    /// The owner said yes to sending the Aurral password and session to `url` over plain http.
    func allowAurralPassword(_ url: URL) {
        aurralPasswordConsent.grant([url])
        allowPlainHTTP([url])
    }

    /// A client for the saved Aurral, signed in as its user; nil without one, or while its address waits for consent
    /// (the password and the token are never sent unencrypted to a public address without the owner's say-so).
    var aurralClient: AurralClient? {
        guard let connection = discover.connection, aurralAllows(connection.base),
              let session = discover.session else { return nil }
        return AurralClient(base: connection.base, session: session, transport: transport)
    }

    /// Round 13 item 1: signs in to Aurral as a user. Checks the address (`/api/health`), logs in
    /// (`POST /api/auth/login`), reads the user's flows, then saves the address, user, session and password to the
    /// Keychain. Throws `PlainHTTPConsentRequired` for a public plain-http address the owner hasn't allowed (nothing
    /// sent), the ATS error, `AurralError.badLogin` for a wrong username or password, `.rateLimited` after too many
    /// tries, `.notFound` for something that isn't Aurral.
    func connectAurral(base: URL, username: String, password: String) async throws -> AurralHealth {
        if atsBlocks(base) { throw Self.atsError(base) }
        guard aurralAllows(base) else { throw PlainHTTPConsentRequired(urls: [base]) }
        let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let probe = AurralClient(base: base, session: AurralSession(username: username, password: nil, login: nil),
                                 transport: transport)
        let health = try await probe.health()
        let login = try await AurralClient.signIn(base: base, username: username, password: password, transport: transport)
        let connection = AurralConnection(base: base, username: username, password: password, login: login)
        let session = discover.makeSession(connection)
        let fresh = AurralClient(base: base, session: session, transport: transport)
        let status: AurralStatus
        var flowsNotPermitted = false
        do {
            do { status = try await fresh.status() } catch AurralError.notPermitted {
                status = AurralStatus(flows: [])   // round 14: no accessFlow; still signed in (Recommended, Trending)
                flowsNotPermitted = true
            }
            if discover.connection != nil { endAurralSession() }   // fix M5: the old session too, same account or not
            try discover.store.save(connection)
        } catch {
            Task { _ = try? await fresh.logout() }   // fix M5: never leave the new session behind
            throw error
        }
        if discover.connection?.account != connection.account { forgetDiscoverReads() }
        discover.use(connection)
        discover.health = health
        discover.flowsNotPermitted = flowsNotPermitted
        noteStatus(status)
        await refreshAurralCapabilities(force: true)   // round 14 fix M3: this user's permissions, fresh
        await refreshDiscover(force: true)
        return health
    }

    /// Settings › Aurral's "Test connection": the version, and whether the session still works (logging in again if
    /// Aurral ended it).
    func testAurral() async throws -> AurralHealth {
        guard let client = aurralClient else { throw AurralError.signInNeeded }
        do {
            let health = try await client.health()
            discover.health = health
            noteStatus(try await client.status())
            return health
        } catch {
            noteAurralError(error)
            throw error
        }
    }

    /// Aurral ended the session and it can't be renewed: Settings asks to sign in again (Discover keeps what it read).
    func noteAurralError(_ error: Error) {
        if case AurralError.signInNeeded? = error as? AurralError { discover.needsSignIn = true }
    }

    /// The owner allowed the saved Aurral's plain-http address.
    func allowAurralAddress() {
        guard let base = discover.connection?.base else { return }
        allowAurralPassword(base)
    }

    /// Settings › Aurral › Sign out: ends the session in Aurral (when it can be reached) and forgets the address,
    /// user, session and password on this iPhone. Discover goes, and Aurral's library is listed again as any other
    /// library would be. Nothing else in Aurral changes.
    func disconnectAurral() {
        endAurralSession()
        discover.store.clear()
        discover.use(nil)
        forgetDiscoverReads()
    }

    /// Sign-out: the Aurral connection goes with the account.
    func forgetDiscover() {
        disconnectAurral()
    }

    /// `POST /api/auth/logout` for the saved session, sent and forgotten (never a new login for it; offline, or
    /// waiting for consent, nothing is sent and the session simply lapses in Aurral).
    private func endAurralSession() {
        guard let client = aurralClient, !isOffline else { return }
        let task = Task { _ = try? await client.logout() }
        discover.pendingLogout = task
    }

    private func forgetDiscoverReads() {
        discover.forgetReads()
        aurralFeeds?.forget()   // round 14 A4: Trending, Recommended and Discover playlists go with the user
        AurralImageProxies.eraseAll(dataDirectory: dataDirectory)   // S14 L3: the picture mapping and memory copies too
        homeFeedSlot?.discard(Set(HomeSection.allCases.filter { $0 == .discover || $0.isProvided }))   // Round 13 Z2: another Aurral (or user) never shows the last one's shelf
        if let scope = navidromeScope {
            appDefaults.removeObject(forKey: Self.discoverPlaylistsKey(scope))
            appDefaults.removeObject(forKey: Self.discoverLibrariesKey(scope))
            appDefaults.removeObject(forKey: Self.aurralSongsKey(scope))
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

    /// Reads Aurral's flows (and its jobs, for the songs' ids) and finds their playlists: named after a flow AND holding
    /// the flow's songs (fix I1, `DiscoverRules.confirmedFlowPlaylists`); a playlist that can't be read keeps what it
    /// was. Then Aurral's library is read again (fix I2). At most every 30 s unless `force`. Offline, or without Aurral,
    /// nothing is asked. A failure keeps what was read before.
    /// Round 13 Z2: only through `refreshDiscover(force:)` / `refreshDiscover(waitingAtMost:)`, one read at a time.
    func performDiscoverRead(force: Bool = false) async {
        guard let client = aurralClient, session != nil, !isOffline, let scope = navidromeScope else { return }
        if !force, let at = discover.statusReadAt, discover.now().timeIntervalSince(at) < 30, !discover.playlists.isEmpty { return }
        let account = discover.connection?.account
        let status: AurralStatus
        do { status = try await client.status() } catch {
            // Round 14: no accessFlow: Discover hides quietly, nothing learnt is wiped (D75, D76).
            if case AurralError.notPermitted? = error as? AurralError { discover.flowsNotPermitted = true }
            noteAurralError(error)
            return
        }
        discover.flowsNotPermitted = false
        guard let all = try? await request({ try await $0.playlists() }) else { return }
        let jobs = (try? await client.jobs()) ?? nil
        guard navidromeScope == scope, discover.connection?.account == account else { return }   // another account or Aurral
        noteStatus(status)
        // Round 13: only the signed-in user's flows' songs (Aurral shows an admin everyone's).
        // Round 14 A4 (D94, amends D75): Add flow's synced playlists are Discover's too, matched like flows (named
        // after one and holding its songs); they never get Refresh Flow (`discoverFlow(playlistId:)`).
        // Fix round 1 (I2): only Add flow's: a Deezer playlist (`importSource.provider` "deezer-playlist", what Discover
        // playlists and charts are) or one this phone added. Spotify or YouTube imports and hand-made shared playlists
        // stay in Playlists.
        let flows = status.flows + status.sharedPlaylists.filter(isAddFlowsPlaylist)
        let flowIds = Set(flows.map(\.id))
        if let jobs { discover.jobs = jobs.filter { $0.flowId.map(flowIds.contains) ?? false } }
        let before = discoverPlaylistIds
        let candidates = DiscoverRules.flowPlaylists(flows: flows, playlists: all)
        var entries: [String: [Song]] = [:]
        // Round 13 Z2: the known Discover playlists no flow is named as now are read too (`discoverPlaylistsToRead`).
        for id in Self.discoverPlaylistsToRead(candidates: candidates, before: before, all: all) {
            if let (_, songs) = try? await request({ try await $0.playlist(id: id) }) {
                entries[id] = songs
            }
        }
        guard navidromeScope == scope, discover.connection?.account == account else { return }
        // Round 13 Z2: a read that can't confirm a playlist (jobs unreadable, a run under way, a playlist that didn't
        // read, no flows listed, a flow renamed first) never takes it out of Discover and into Playlists.
        let matched = keptDiscoverPlaylists(flows: flows, all: all, candidates: candidates, entries: entries,
                                            before: before)
        discover.playlists = matched
        appDefaults.set(matched.map(\.playlist.id), forKey: Self.discoverPlaylistsKey(scope))
        for playlist in matched { noteFlowSongs(entries[playlist.playlist.id] ?? []) }
        if Set(matched.map(\.playlist.id)) != before {
            libraryEdits.playlistsRevision += 1   // Playlists read again
            homeFeedSlot?.sectionsChanged([.discover, .playlists])   // Round 13 Z2: and Home's two shelves
        }
        await refreshAurralLibrary(entries: matched.flatMap { entries[$0.playlist.id] ?? [] })
    }

    /// Fix I2: every song in Aurral's library (flow songs, and the ones rotated out but still kept because a playlist
    /// holds them), read with the server's library filter and saved for the account, so "Use your library's copy"
    /// recognises them after the flow moved on and after a relaunch. The library is learnt first when unknown (from
    /// the flow songs' lookups).
    func refreshAurralLibrary(entries: [Song]) async {
        guard let scope = navidromeScope else { return }
        if savedDiscoverLibraryIds.isEmpty, !entries.isEmpty { _ = await libraryCopies(for: entries, flowId: nil) }
        var ids = Set(entries.map(\.id))
        for library in savedDiscoverLibraryIds.sorted() {
            guard let read = try? await request({ try await $0.songs(inLibrary: library, maxPages: 20) }) else { return }
            ids.formUnion(read.songs.map(\.id))
        }
        guard navidromeScope == scope else { return }
        discover.aurralSongIds = ids
        appDefaults.set(Array(ids).sorted().prefix(Self.aurralSongsLimit).map { $0 }, forKey: Self.aurralSongsKey(scope))
    }

    nonisolated static let aurralSongsLimit = 10_000

    /// The songs known to be Aurral's copies: as last read (this session), else as saved for the account, and every
    /// flow song seen.
    var knownAurralSongIds: Set<String> {
        var ids = discover.aurralSongIds.union(discover.flowSongIds)
        if discover.aurralSongIds.isEmpty, aurralSetUp, let scope = navidromeScope {
            ids.formUnion(appDefaults.stringArray(forKey: Self.aurralSongsKey(scope)) ?? [])
        }
        return ids
    }

    /// Discover's playlists for Home, Library and the car: read again when stale; if Aurral doesn't answer, the
    /// server's playlists that were Discover's last time.
    func discoverPlaylists() async throws -> [Playlist] {
        guard aurralSetUp, !isOffline else { return [] }
        await refreshDiscover(waitingAtMost: Self.discoverWait)   // Round 13 Z2: never held up by a slow Aurral
        guard !discover.flowsNotPermitted else { return [] }   // round 14: no accessFlow, Discover hides
        if !discover.playlists.isEmpty { return discover.playlists.map(\.playlist) }
        let ids = discoverPlaylistIds
        guard !ids.isEmpty else { return [] }
        return try await request { try await $0.playlists() }.filter { ids.contains($0.id) }
    }

    /// The flow a Discover playlist belongs to, if known.
    func discoverFlow(playlistId: String) -> AurralFlow? {
        // Round 13 Z2: a playlist kept without a known flow (`keptDiscoverPlaylists`) has none: no Refresh Flow.
        // Round 14 A4: nor has a synced playlist (Add flow's: Aurral re-syncs it daily itself).
        guard let flow = discover.playlists.first(where: { $0.playlist.id == playlistId })?.flow.nonEmpty,
              !isSyncedPlaylist(flowId: flow.id) else { return nil }
        return flow
    }

    /// Round 14 A4: the synced playlist (Add flow's) a Discover playlist is, if it is one.
    func discoverSyncedPlaylist(playlistId: String) -> AurralFlow? {
        guard let flow = discover.playlists.first(where: { $0.playlist.id == playlistId })?.flow.nonEmpty,
              isSyncedPlaylist(flowId: flow.id) else { return nil }
        return flow
    }

    func isSyncedPlaylist(flowId: String) -> Bool {
        discover.status?.sharedPlaylists.contains { $0.id == flowId } ?? false
    }

    /// Round 14 A4 fix round 1 (I2): a shared playlist Add flow made (a Deezer playlist, or one this phone added).
    func isAddFlowsPlaylist(_ playlist: AurralFlow) -> Bool {
        playlist.importProvider == "deezer-playlist" || (aurralFeeds?.added.values.contains(playlist.id) ?? false)
    }

    // MARK: - A Discover playlist's page

    /// The playlist with each flow song the main library has shown as the library's copy, in its place. Each song's
    /// lookup is kept for the session (`lookupLifetime`); `fresh` (pull to refresh) looks them all up again.
    func discoverPage(playlistId: String, fresh: Bool = false) async throws -> DiscoverPage {
        let (playlist, songs) = try await request { try await $0.playlist(id: playlistId) }
        noteFlowSongs(songs)
        let flow = discoverFlow(playlistId: playlistId)
        let copies = await libraryCopies(for: songs, flowId: flow?.id, fresh: fresh)
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

    /// How long a song's lookup (its library copy, or none) is kept (fix M1).
    nonisolated static let lookupLifetime: TimeInterval = 30 * 60

    /// The main library's copy of each of `songs` that has one (by the song's id). Looks each song up: by recording id
    /// (the song's, else Aurral's job's) through the server's lookup, which also says which library each copy is in
    /// (and so where Aurral's files are: `learnDiscoverLibrary`); else by title, matched on artist + title + duration.
    /// A lookup made in the last `lookupLifetime` is used as it is (hits and misses), unless `fresh`. The match index
    /// isn't used: it answers ids only and matches by name too, which the swap never does.
    func libraryCopies(for songs: [Song], flowId: String?, fresh: Bool = false) async -> [String: Song] {
        guard session != nil, !isOffline, !songs.isEmpty else { return [:] }
        let now = discover.now()
        let jobs = discover.jobs
        let excluding = knownAurralSongIds.union(songs.map(\.id)).union(findSongs.map(\.id))
        let libraries = listedLibraryIds.map(Set.init)
        let notLibraries = separateLibraryIds
        var copies: [String: Song] = [:]
        var rows: [String: [Song]] = [:]
        var toLookUp: [Song] = []
        for song in songs {
            if !fresh, let known = discover.lookups[song.id], now.timeIntervalSince(known.at) < Self.lookupLifetime {
                if let copy = known.copy { copies[song.id] = copy }
            } else if !toLookUp.contains(where: { $0.id == song.id }) {
                toLookUp.append(song)
            }
        }
        await withTaskGroup(of: (String, Song?, [Song]).self) { group in
            var started = 0
            for song in toLookUp {
                if started >= 4, let done = await group.next() {   // four at a time
                    copies[done.0] = done.1
                    rows[done.0] = done.2
                }
                started += 1
                let recording = song.recordingMBID ?? DiscoverRules.jobRecording(for: song, jobs: jobs, flowId: flowId)
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
        for song in toLookUp { discover.lookups[song.id] = DiscoverLookup(copy: copies[song.id], at: now) }
        let found = copies.compactMapValues { $0 }
        for song in songs { discover.copies[song.id] = found[song.id] }
        learnDiscoverLibrary(entries: toLookUp, rows: rows)
        return found
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

    /// How long a Refresh Flow Magpie sent counts as under way without Aurral's status showing it (fix I3).
    nonisolated static let refreshLatchLimit: TimeInterval = 120

    /// Refresh Flow (after the owner confirmed "Replaces this playlist's songs"): read Aurral's status fresh and refuse
    /// while a run is under way (`AurralError.runActive`, nothing sent); otherwise start the flow's run.
    func refreshFlow(_ flowId: String) async throws {
        guard !isOffline else { throw Self.forcedOfflineError }
        guard let client = aurralClient else { throw AurralError.unauthorized }
        let status = try await client.status()
        noteStatus(status)
        guard !isFlowRunActive(flowId) else { throw AurralError.runActive }
        let lastRun = status.flows.first { $0.id == flowId }?.lastRunAt
        discover.refreshing[flowId] = RefreshLatch(startedAt: discover.now(), lastRunAt: lastRun)
        do {
            _ = try await client.startFlow(flowId)
        } catch {
            discover.refreshing[flowId] = nil
            throw error
        }
        if let fresh = try? await client.status() { noteStatus(fresh) }
    }

    /// Reads the worker's progress again (the page polls while a run is under way).
    func refreshDiscoverStatus() async {
        guard let client = aurralClient, !isOffline, let status = try? await client.status() else { return }
        noteStatus(status)
    }

    /// Takes a status read, and lets go of each Refresh Flow Magpie sent once Aurral's status speaks for it (fix I3):
    /// it shows the run (from then on the status says when it ends), the flow's last run moved (it finished between
    /// reads), or `refreshLatchLimit` passed without either (it failed at once, or was never queued).
    func noteStatus(_ status: AurralStatus) {
        discover.status = status
        discover.statusReadAt = discover.now()
        let now = discover.now()
        for (flowId, latch) in discover.refreshing {
            let lastRun = status.flows.first { $0.id == flowId }?.lastRunAt
            if status.isRunActive(flowId: flowId) || (lastRun != nil && lastRun != latch.lastRunAt)
                || now.timeIntervalSince(latch.startedAt) > Self.refreshLatchLimit {
                discover.refreshing[flowId] = nil
            }
        }
    }

    /// Whether the flow's run is under way (Refresh Flow is then refused): Aurral's status says so, or Magpie just
    /// started it and Aurral hasn't spoken for it yet (at most `refreshLatchLimit`).
    func isFlowRunActive(_ flowId: String) -> Bool {
        if discover.status?.isRunActive(flowId: flowId) ?? false { return true }
        guard let latch = discover.refreshing[flowId] else { return false }
        return discover.now().timeIntervalSince(latch.startedAt) <= Self.refreshLatchLimit
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
    nonisolated static let aurralSongsKeyPrefix = "magpie.aurralSongs."
    nonisolated static func aurralSongsKey(_ scope: String) -> String { aurralSongsKeyPrefix + scope }
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
    /// Round 13: the session ended and Magpie couldn't sign in again by itself.
    static let signInAgain = "Discover\u{2019}s server signed you out. Sign in again in Settings."
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
        case .unauthorized?: "Discover\u{2019}s server said no. Check your account in Settings."
        case .notPermitted?: "Your account on Discover\u{2019}s server isn\u{2019}t allowed to do that."
        case .signInNeeded?, .badLogin?: signInAgain
        case .rateLimited?: AurralCopy.rateLimited
        case .notFound?: "That flow isn\u{2019}t there any more."
        case .forbidden?: "Magpie doesn\u{2019}t send that."
        default: AppModel.isConnectionError(error) ? "Discover\u{2019}s server isn\u{2019}t answering right now." : BrowseErrorCopy.message(for: error)
        }
    }
}
