import Foundation
import MagpieCore
import os

public actor NavidromeClient {
    /// Everything `nonisolated` URL builders need, readable without hopping onto the actor.
    private struct Session: Sendable {
        var base: URL?
        var login: LoginResult?
        var generation = 0
    }

    private let endpoint: ServerEndpoint
    private let credentials: NavidromeCredentials
    private let transport: HTTPTransport
    private let clientName: String
    private let now: @Sendable () -> Date
    private let session = OSAllocatedUnfairLock(initialState: Session())
    private var loginTask: Task<Session, Error>?
    private var lastScan: [String: Date] = [:]
    private static let scanDebounce: TimeInterval = 10
    private static let log = Log.logger("navidrome")

    public init(endpoint: ServerEndpoint, credentials: NavidromeCredentials, transport: HTTPTransport,
                clientName: String = "Magpie", now: @escaping @Sendable () -> Date = { Date() }) {
        self.endpoint = endpoint
        self.credentials = credentials
        self.transport = transport
        self.clientName = clientName
        self.now = now
    }

    // MARK: - Connect and auth

    /// Picks the first base answering `/rest/ping` with a Subsonic answer, then logs in. Concurrent callers share one login.
    public func connect() async throws -> LoginResult {
        let s = try await singleFlightLogin(reprobe: true, staleGeneration: nil)
        return s.login!
    }

    private func currentSession() async throws -> Session {
        let s = session.withLock { $0 }
        if s.login != nil, s.base != nil { return s }
        return try await singleFlightLogin(reprobe: true, staleGeneration: nil)
    }

    /// Single-flight login. A caller whose request failed under `staleGeneration` skips the login when
    /// somebody else has already refreshed the session since.
    private func singleFlightLogin(reprobe: Bool, staleGeneration: Int?) async throws -> Session {
        if let stale = staleGeneration {
            let s = session.withLock { $0 }
            if s.generation > stale, s.login != nil { return s }
        }
        if let task = loginTask { return try await task.value }
        let task = Task { try await self.performLogin(reprobe: reprobe) }
        loginTask = task
        defer { loginTask = nil }
        return try await task.value
    }

    private func performLogin(reprobe: Bool) async throws -> Session {
        var base = session.withLock { $0.base }
        if reprobe || base == nil {
            let transport = self.transport
            let endpoint = self.endpoint
            let clientName = self.clientName
            base = await firstReachable(endpoint) { candidate in
                let url = endpoint.url(candidate, path: "rest/ping", query: [
                    URLQueryItem(name: "v", value: SubsonicAuth.apiVersion),
                    URLQueryItem(name: "c", value: clientName),
                    URLQueryItem(name: "f", value: "json"),
                ])
                guard let (data, response) = try? await transport.send(URLRequest(url: url)) else { return false }
                // Security H2: a 200 from a router or captive portal is not a server; the password stays home.
                return (200..<300).contains(response.statusCode) && SubsonicPing.isServerAnswer(data)
            }
        }
        guard let base else { throw NavidromeError.noReachableServer }

        var request = URLRequest(url: endpoint.url(base, path: "auth/login"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["username": credentials.username,
                                                      "password": credentials.password])
        Log.request(request)
        let (data, response) = try await transport.send(request)
        switch response.statusCode {
        case 200..<300: break
        case 401, 403: throw NavidromeError.badCredentials
        default: throw NavidromeError.http(status: response.statusCode)
        }
        let dto = try Self.decode(LoginDTO.self, data)
        let login = LoginResult(userId: dto.id, isAdmin: dto.isAdmin ?? false,
                                username: dto.username ?? credentials.username, jwt: dto.token,
                                subsonicToken: dto.subsonicToken ?? "", subsonicSalt: dto.subsonicSalt ?? "")
        return session.withLock { s in
            s.base = base
            s.login = login
            s.generation += 1
            return s
        }
    }

    // MARK: - Request plumbing

    /// Sends with the current session; on an auth failure re-logs in (single-flight) and retries once.
    private func authorized(_ make: @Sendable (Session) -> URLRequest,
                            isExpired: @Sendable (Data, HTTPURLResponse) -> Bool) async throws -> (Data, HTTPURLResponse) {
        var current = try await currentSession()
        for attempt in 0..<2 {
            let request = make(current)
            Log.request(request)
            let result = try await transport.send(request)
            if attempt == 0, isExpired(result.0, result.1) {
                current = try await singleFlightLogin(reprobe: false, staleGeneration: current.generation)
                continue
            }
            return result
        }
        preconditionFailure("unreachable")
    }

    private static func subsonicAuthFailure(_ data: Data, _ response: HTTPURLResponse) -> Bool {
        if response.statusCode == 401 { return true }
        guard let code = try? JSONDecoder().decode(SubsonicEnvelope.self, from: data).response.error?.code else { return false }
        return code == 40 || code == 44
    }

    private nonisolated func subsonicURL(_ method: String, _ s: Session, _ extra: [URLQueryItem]) -> URL {
        Self.subsonicURL(endpoint: endpoint, session: s, method: method, extra: extra,
                         password: credentials.password, clientName: clientName)
    }

    private static func subsonicURL(endpoint: ServerEndpoint, session s: Session, method: String,
                                    extra: [URLQueryItem], password: String, clientName: String) -> URL {
        let base = s.base ?? endpoint.bases[0]
        let auth = s.login.map { SubsonicAuth.queryItems(login: $0, password: password, clientName: clientName) } ?? []
        return endpoint.url(base, path: "rest/\(method)", query: auth + extra)
    }

    private func subsonic(_ method: String, _ extra: [URLQueryItem] = []) async throws -> SubsonicBody {
        let (data, response) = try await authorized({ s in
            URLRequest(url: self.subsonicURL(method, s, extra))
        }, isExpired: Self.subsonicAuthFailure)
        guard (200..<300).contains(response.statusCode) else {
            throw response.statusCode == 401 ? NavidromeError.badCredentials : NavidromeError.http(status: response.statusCode)
        }
        let body = try Self.decode(SubsonicEnvelope.self, data).response
        if body.status != "ok" {
            let error = body.error
            if error?.code == 40 || error?.code == 44 { throw NavidromeError.badCredentials }
            throw NavidromeError.api(code: error?.code ?? 0, message: error?.message ?? "")
        }
        return body
    }

    /// A body that isn't JSON at all (a proxy's HTML sign-in page, a captive portal, nothing) is
    /// `unexpectedResponse`; JSON in a shape Magpie can't read is `unexpectedData`.
    private static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: data) } catch is DecodingError {
            let first = data.first { !$0.isASCIIWhitespace }
            throw first == UInt8(ascii: "{") || first == UInt8(ascii: "[")
                ? NavidromeError.unexpectedData : NavidromeError.unexpectedResponse
        }
    }

    private func int(_ name: String, _ v: Int) -> URLQueryItem { URLQueryItem(name: name, value: String(v)) }

    // MARK: - Browse

    public func albumList(_ type: AlbumListType, size: Int, offset: Int) async throws -> [Album] {
        let body = try await subsonic("getAlbumList2", [
            URLQueryItem(name: "type", value: type.rawValue), int("size", size), int("offset", offset),
        ])
        return (body.albumList2?.album ?? []).map { Mapping.album($0) }
    }

    public func album(id: String) async throws -> Album {
        let body = try await subsonic("getAlbum", [URLQueryItem(name: "id", value: id)])
        guard let album = body.album else { throw NavidromeError.api(code: 70, message: "album missing from response") }
        return Mapping.album(album, withSongs: true)
    }

    /// One song by id (a request that just became Ready, D6).
    public func song(id: String) async throws -> Song {
        let body = try await subsonic("getSong", [URLQueryItem(name: "id", value: id)])
        guard let song = body.song else { throw NavidromeError.api(code: 70, message: "song missing from response") }
        return Mapping.song(song)
    }

    public func artists() async throws -> [Artist] {
        let body = try await subsonic("getArtists")
        return (body.artists?.index ?? []).flatMap { $0.artist ?? [] }.map(Mapping.artist)
    }

    public func artist(id: String) async throws -> (Artist, [Album]) {
        let body = try await subsonic("getArtist", [URLQueryItem(name: "id", value: id)])
        guard let artist = body.artist else { throw NavidromeError.api(code: 70, message: "artist missing from response") }
        return (Mapping.artist(artist), (artist.album ?? []).map { Mapping.album($0) })
    }

    public func playlists() async throws -> [Playlist] {
        let body = try await subsonic("getPlaylists")
        return (body.playlists?.playlist ?? []).map(Mapping.playlist)
    }

    public func playlist(id: String) async throws -> (Playlist, [Song]) {
        let body = try await subsonic("getPlaylist", [URLQueryItem(name: "id", value: id)])
        guard let playlist = body.playlist else { throw NavidromeError.api(code: 70, message: "playlist missing from response") }
        return (Mapping.playlist(playlist), (playlist.entry ?? []).map(Mapping.song))
    }

    public func search(_ q: String, songCount: Int = 20, albumCount: Int = 10, artistCount: Int = 5) async throws -> LibrarySearchResult {
        let body = try await subsonic("search3", [
            URLQueryItem(name: "query", value: q), int("songCount", songCount),
            int("albumCount", albumCount), int("artistCount", artistCount),
        ])
        let r = body.searchResult3
        return LibrarySearchResult(songs: (r?.song ?? []).map(Mapping.song),
                                   albums: (r?.album ?? []).map { Mapping.album($0) },
                                   artists: (r?.artist ?? []).map(Mapping.artist))
    }

    public func extensions() async throws -> Set<String> {
        let body = try await subsonic("getOpenSubsonicExtensions")
        return Set((body.openSubsonicExtensions ?? []).map(\.name))
    }

    public func lyrics(songId: String) async throws -> Lyrics? {
        do {
            let body = try await subsonic("getLyricsBySongId", [URLQueryItem(name: "id", value: songId)])
            return Mapping.lyrics(body.lyricsList)
        } catch NavidromeError.api(code: 70, _) {
            return nil
        }
    }

    /// May be empty: needs the server's Last.fm agent.
    public func topSongs(artistName: String) async throws -> [Song] {
        let body = try await subsonic("getTopSongs", [URLQueryItem(name: "artist", value: artistName)])
        return (body.topSongs?.song ?? []).map(Mapping.song)
    }

    // MARK: - URLs (usable from any context; auth comes from the latest session)

    public nonisolated func streamURL(songId: String, maxBitRate: Int?, format: String?) -> URL {
        var extra = [URLQueryItem(name: "id", value: songId)]
        if let maxBitRate { extra.append(URLQueryItem(name: "maxBitRate", value: String(maxBitRate))) }
        if let format { extra.append(URLQueryItem(name: "format", value: format)) }
        extra.append(URLQueryItem(name: "estimateContentLength", value: "true"))
        return Self.subsonicURL(endpoint: endpoint, session: session.withLock { $0 }, method: "stream",
                                extra: extra, password: credentials.password, clientName: clientName)
    }

    public nonisolated func coverArtURL(id: String, size: Int) -> URL {
        Self.subsonicURL(endpoint: endpoint, session: session.withLock { $0 }, method: "getCoverArt",
                         extra: [URLQueryItem(name: "id", value: id), URLQueryItem(name: "size", value: String(size))],
                         password: credentials.password, clientName: clientName)
    }

    // MARK: - Writes

    public func scrobble(songId: String, submission: Bool, at: Date?) async throws {
        var extra = [URLQueryItem(name: "id", value: songId),
                     URLQueryItem(name: "submission", value: submission ? "true" : "false")]
        if let at { extra.append(URLQueryItem(name: "time", value: String(Int64(at.timeIntervalSince1970 * 1000)))) }
        _ = try await subsonic("scrobble", extra)
    }

    /// Stars ("likes") a song, album or artist by id.
    public func star(id: String) async throws {
        _ = try await subsonic("star", [URLQueryItem(name: "id", value: id)])
    }

    /// Removes a star.
    public func unstar(id: String) async throws {
        _ = try await subsonic("unstar", [URLQueryItem(name: "id", value: id)])
    }

    /// Quick scan (`fullScan=false`). `target` is `<libraryId>:<path relative to that library>`.
    /// At most one scan per target per 10 s; a debounced call returns without contacting the server.
    public func startScan(target: String?) async throws {
        try await startScan(targets: target.map { [$0] } ?? [])
    }

    /// One quick scan of several targets (A12; Keep scans the folder a find left and the one it moved to).
    /// Empty: the whole library. Debounced per set of targets like `startScan(target:)`.
    public func startScan(targets: [String]) async throws {
        let key = targets.joined(separator: "\u{1F}")
        let t = now()
        if let last = lastScan[key], t.timeIntervalSince(last) < Self.scanDebounce { return }
        var extra = [URLQueryItem(name: "fullScan", value: "false")]
        extra += targets.map { URLQueryItem(name: "target", value: $0) }
        _ = try await subsonic("startScan", extra)
        lastScan[key] = t   // only after success: a failed scan must be retryable immediately
    }

    public func scanStatus() async throws -> Bool {
        let body = try await subsonic("getScanStatus")
        return body.scanStatus?.scanning ?? false
    }

    // MARK: - Native API

    /// One page of the whole library via `/api/song`; `end` is exclusive. Songs flagged `missing` are skipped.
    public func songsPage(start: Int, end: Int) async throws -> (songs: [Song], total: Int) {
        let query = [int("_start", start), int("_end", end),
                     URLQueryItem(name: "_sort", value: "id"), URLQueryItem(name: "_order", value: "ASC")]
        let (data, response) = try await native("api/song", query)
        let rows = try Self.decode([NativeSong].self, data)
        let songs = rows.filter { $0.missing != true }.map(Mapping.song)
        // Without the header (a proxy dropped it), a full page means there may be more; a short one is the end.
        let total = response.value(forHTTPHeaderField: "X-Total-Count").flatMap { Int($0) }
            ?? (rows.count < end - start ? start + rows.count : end + 1)
        return (songs, total)
    }

    /// One library folder's songs as read, and whether that is all of them.
    public struct LibrarySongs: Sendable, Equatable {
        public var songs: [Song]
        /// False when the read stopped at the page limit with more songs left: the list is partial (FM2: a song not
        /// in it may still be in the library).
        public var complete: Bool

        public init(songs: [Song], complete: Bool) { self.songs = songs; self.complete = complete }
    }

    /// Every song of one library folder (the Finds shelf, Task 6.2a), via `/api/song?library_id=`. Rows of
    /// another library are dropped too, in case a server ignores the filter; at most `maxPages` pages (100,000
    /// songs by default), and `complete` says whether that was all (security FM2: never a silent cap).
    public func songs(inLibrary libraryId: Int, pageSize: Int = 500, maxPages: Int = 200) async throws -> LibrarySongs {
        var songs: [Song] = [], seen = Set<String>(), start = 0
        for _ in 0..<maxPages {
            let query = [int("library_id", libraryId), int("_start", start), int("_end", start + pageSize),
                         URLQueryItem(name: "_sort", value: "id"), URLQueryItem(name: "_order", value: "ASC")]
            let (data, response) = try await native("api/song", query)
            let rows = try Self.decode([NativeSong].self, data)
            for song in rows.filter({ $0.missing != true && $0.libraryId == libraryId }).map(Mapping.song)
            where seen.insert(song.id).inserted {
                songs.append(song)
            }
            start += pageSize
            let total = response.value(forHTTPHeaderField: "X-Total-Count").flatMap { Int($0) }
            if rows.count < pageSize || total.map({ start >= $0 }) == true { return LibrarySongs(songs: songs, complete: true) }
        }
        return LibrarySongs(songs: songs, complete: false)
    }

    /// Songs with this MusicBrainz recording id (`/api/song?mbz_recording_id=`, verified on 0.64.2), outside
    /// `excludingLibrary`. Exact id matches only; missing rows dropped.
    public func songs(recordingMBID: MBID, excludingLibrary: Int?) async throws -> [Song] {
        try await recordingRows(recordingMBID).filter { excludingLibrary == nil || $0.libraryId != excludingLibrary }
            .map(Mapping.song)
    }

    /// Keep (A3): the recording's songs in library `libraryId` under `folder` (relative to that library, compared
    /// component by component), i.e. where a kept find moved, never the owner's own copy on another release.
    public func songs(recordingMBID: MBID, inLibrary libraryId: Int, under folder: String) async throws -> [Song] {
        // Split and compared on bytes (security FL1): a combining mark after `/` can't hide a component.
        let components = { (p: String) in p.utf8.split(separator: UInt8(ascii: "/")).map(Array.init) }
        let prefix = components(folder)
        return try await recordingRows(recordingMBID).filter { row in
            guard row.libraryId == libraryId, !prefix.isEmpty, let parts = row.path.map(components),
                  parts.count > prefix.count else {
                return false
            }
            return Array(parts.prefix(prefix.count)) == prefix
        }.map(Mapping.song)
    }

    private func recordingRows(_ recording: MBID) async throws -> [NativeSong] {
        let query = [URLQueryItem(name: "mbz_recording_id", value: recording.rawValue), int("_start", 0), int("_end", 50),
                     URLQueryItem(name: "_sort", value: "id"), URLQueryItem(name: "_order", value: "ASC")]
        let (data, _) = try await native("api/song", query)
        return try Self.decode([NativeSong].self, data)
            .filter { $0.missing != true && $0.mbzRecordingID.flatMap { MBID($0) } == recording }
    }

    /// The library folders and their paths as Navidrome sees them (`/api/library`; B6, G2). Some versions
    /// answer 403 to non-admin accounts (`NavidromeError.http(status: 403)`).
    public func libraries() async throws -> [NavidromeLibrary] {
        let (data, _) = try await native("api/library", [])
        return try Self.decode([NativeLibrary].self, data).map { NavidromeLibrary(id: $0.id, name: $0.name ?? "", path: $0.path) }
    }

    /// A GET on the native API with the session's JWT; keeps a refreshed token. Throws for a non-2xx answer.
    private func native(_ path: String, _ query: [URLQueryItem]) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await authorized({ s in
            var request = URLRequest(url: self.endpoint.url(s.base ?? self.endpoint.bases[0], path: path, query: query))
            request.setValue("Bearer \(s.login?.jwt ?? "")", forHTTPHeaderField: "X-ND-Authorization")
            return request
        }, isExpired: { _, r in r.statusCode == 401 })
        guard (200..<300).contains(response.statusCode) else {
            throw response.statusCode == 401 ? NavidromeError.badCredentials : NavidromeError.http(status: response.statusCode)
        }
        if let refreshed = response.value(forHTTPHeaderField: "X-ND-Authorization")?
            .replacingOccurrences(of: "Bearer ", with: ""), !refreshed.isEmpty {
            session.withLock { $0.login?.jwt = refreshed }
        }
        return (data, response)
    }
}

private extension UInt8 {
    var isASCIIWhitespace: Bool { self == 0x20 || self == 0x09 || self == 0x0A || self == 0x0D }
}
