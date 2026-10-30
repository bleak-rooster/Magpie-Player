import Foundation
import MagpieCore
import MagpieTestSupport
import Testing
@testable import NavidromeKit

/// Crash hunt 4: seeded mutations of every NavidromeKit endpoint's answer. Decoding never traps: it throws a
/// `NavidromeError` or gives models that every screen and car builder can show (`UISink`).
@Suite(.serialized) struct NavidromeFuzzTests {
    static let base = URL(string: "https://music.example/navidrome")!

    /// A connected client whose every endpoint answers `answer` (ping and login stay well-formed).
    static func connected(_ answer: Answer) async throws -> NavidromeClient {
        let t = MockTransport()
        t.stub(pathSuffix: "/rest/ping", body: Fixture.data("navidrome", "getOpenSubsonicExtensions"))
        t.stub(method: "POST", pathSuffix: "/auth/login", body: Fixture.data("navidrome", "login"))
        t.stub(pathSuffix: "") { _ in answer.response }
        let client = NavidromeClient(endpoint: ServerEndpoint(bases: [base]),
                                     credentials: NavidromeCredentials(username: "u", password: "p"), transport: t)
        _ = try await client.connect()
        return client
    }

    static func envelope(_ payload: String) -> Data {
        Data(#"{"subsonic-response":{"status":"ok","version":"1.16.1",\#(payload)}}"#.utf8)
    }

    static let song = #"{"id":"s1","title":"Song","artist":"A","artistId":"ar1","album":"B","albumId":"al1","track":3,"discNumber":1,"duration":201.5,"suffix":"flac","bitRate":900,"coverArt":"c1","musicBrainzId":"c2272a15-9d25-4fd2-a0ae-0f4ab3c7f9d1","isrc":["GBAYE0601498"],"starred":"2024-01-01T00:00:00Z","genre":"Rock; Pop","replayGain":{"trackGain":-6.5,"albumGain":-7,"trackPeak":0.98,"albumPeak":1}}"#

    /// One Subsonic endpoint: its seed answer and the call that reads it, feeding the result to the UI builders.
    struct Endpoint: Sendable {
        var name: String
        var seed: Data
        var call: @Sendable (NavidromeClient) async throws -> Void
    }

    static let endpoints: [Endpoint] = [
        Endpoint(name: "getAlbumList2", seed: Fixture.data("navidrome", "getAlbumList2")) {
            UISink.albums(try await $0.albumList(.newest, size: 50, offset: 0))
        },
        Endpoint(name: "getAlbum multidisc", seed: Fixture.data("navidrome", "getAlbum-multidisc")) {
            let album = try await $0.album(id: "a"); UISink.albums([album]); UISink.songs(album.songs ?? [])
        },
        Endpoint(name: "getAlbum compilation", seed: Fixture.data("navidrome", "getAlbum-compilation")) {
            UISink.albums([try await $0.album(id: "a")])
        },
        Endpoint(name: "getArtists", seed: Fixture.data("navidrome", "getArtists")) { UISink.artists(try await $0.artists()) },
        Endpoint(name: "getArtist", seed: Fixture.data("navidrome", "getArtist")) {
            let (artist, albums) = try await $0.artist(id: "x"); UISink.artists([artist]); UISink.albums(albums)
        },
        Endpoint(name: "getPlaylists", seed: Fixture.data("navidrome", "getPlaylists")) { UISink.playlists(try await $0.playlists()) },
        Endpoint(name: "getPlaylist", seed: Fixture.data("navidrome", "getPlaylist")) {
            let (playlist, songs) = try await $0.playlist(id: "p"); UISink.playlists([playlist]); UISink.songs(songs)
        },
        Endpoint(name: "search3", seed: Fixture.data("navidrome", "search3")) {
            let r = try await $0.search("q"); UISink.songs(r.songs); UISink.albums(r.albums); UISink.artists(r.artists)
        },
        Endpoint(name: "getTopSongs", seed: Fixture.data("navidrome", "getTopSongs")) { UISink.songs(try await $0.topSongs(artistName: "a")) },
        Endpoint(name: "getLyricsBySongId", seed: Fixture.data("navidrome", "getLyricsBySongId")) {
            if let lyrics = try await $0.lyrics(songId: "s") { #expect(lyrics.lines.allSatisfy { $0.start.map { !$0.isNaN } ?? true }) }
        },
        Endpoint(name: "getOpenSubsonicExtensions", seed: Fixture.data("navidrome", "getOpenSubsonicExtensions")) {
            _ = try await $0.extensions()
        },
        Endpoint(name: "getGenres", seed: envelope(#""genres":{"genre":[{"value":"Rock","songCount":12,"albumCount":3},{"value":"Drum & Bass","songCount":4,"albumCount":1},{"value":"Jazz/Blues; Folk","songCount":0,"albumCount":0},{"value":"Pop"}]}"#)) {
            UISink.genres(try await $0.genres())
        },
        Endpoint(name: "getStarred2", seed: envelope(#""starred2":{"song":[\#(song),\#(song)],"album":[{"id":"al1","name":"B","artist":"A","songCount":2,"duration":400,"year":1999}]}"#)) {
            let s = try await $0.starred(); UISink.songs(s.songs); UISink.albums(s.albums)
        },
        Endpoint(name: "getSongsByGenre", seed: envelope(#""songsByGenre":{"song":[\#(song)]}"#)) {
            UISink.songs(try await $0.songs(genre: "Rock", count: 50, offset: 0))
        },
        Endpoint(name: "getSong", seed: envelope(#""song":\#(song)"#)) { UISink.songs([try await $0.song(id: "s1")]) },
        Endpoint(name: "getScanStatus", seed: envelope(#""scanStatus":{"scanning":true,"count":12}"#)) { _ = try await $0.scanStatus() },
    ]

    /// 5,000+ mutated Subsonic answers across the endpoints (seeded: the same cases every run).
    @Test func subsonicEndpointsNeverTrap() async throws {
        let answer = Answer()
        let client = try await Self.connected(answer)
        var fuzzer = JSONFuzzer(seed: 0x5B50_4E1C)
        var stats = SweepStats()
        let perEndpoint = 5_000 / Self.endpoints.count + 1
        let total = await FuzzClock.seconds {
            for endpoint in Self.endpoints {
                for _ in 0..<perEndpoint {
                    let body = fuzzer.mutate(endpoint.seed)
                    if ProcessInfo.processInfo.environment["HUNT_TRACE"] != nil {
                        try? body.write(to: FileManager.default.temporaryDirectory.appending(path: "hunt4-subsonic-last.json"))
                        FileHandle.standardError.write(Data("\(endpoint.name) \(stats.cases)\n".utf8))
                    }
                    answer.set(body, status: fuzzer.rng.chance(0.03) ? [500, 404, 302][Int.random(in: 0..<3, using: &fuzzer.rng)] : 200)
                    var ok = true
                    let t = await FuzzClock.seconds {
                        do { try await endpoint.call(client) } catch {
                            ok = false
                            #expect(error is NavidromeError, "\(endpoint.name): \(error)")
                        }
                    }
                    if t > 0.3, ProcessInfo.processInfo.environment["HUNT_TRACE"] != nil {
                        try? body.write(to: FileManager.default.temporaryDirectory.appending(path: "hunt4-slow-\(stats.cases).json"))
                        FileHandle.standardError.write(Data("SLOW \(endpoint.name) \(stats.cases) \(t)s \(body.count)B ok=\(ok)\n".utf8))
                    }
                    stats.record(seconds: t, ok: ok)
                }
            }
        }
        #expect(stats.cases >= 5_000)
        #expect(stats.decoded > 500 && stats.errors > 100)   // the sweep exercises both outcomes
        #expect(stats.slowest < 3, // ~0.1 s idle; quadratic blow-ups take many seconds; headroom for loaded machines
            "slowest case \(stats.slowest) s")
        #expect(total < 9, "sweep took \(total) s")
    }

    /// 5,000+ mutated native-API answers (`/api/song` pages with a fuzzed `X-Total-Count`, `/api/library`), and the
    /// sign-in and ping answers.
    @Test func nativeEndpointsLoginAndPingNeverTrap() async throws {
        let answer = Answer()
        let client = try await Self.connected(answer)
        let page = Fixture.data("navidrome", "apiSongPage"), libraries = Fixture.data("navidrome", "apiLibrary")
        let login = Fixture.data("navidrome", "login"), ping = Fixture.data("navidrome", "getOpenSubsonicExtensions")
        let mbid = try #require(MBID("c2272a15-9d25-4fd2-a0ae-0f4ab3c7f9d1"))
        let totals = ["", "-1", "0", "3", "9223372036854775807", "-9223372036854775808", "99999999999999999999", "abc", " 12", "1e3"]
        var fuzzer = JSONFuzzer(seed: 0xA11_50C6)
        var stats = SweepStats()
        let total = await FuzzClock.seconds {
            for i in 0..<5_200 {
                let headers = fuzzer.rng.chance(0.6) ? ["X-Total-Count": totals.randomElement(using: &fuzzer.rng)!] : [:]
                var ok = true
                let t = await FuzzClock.seconds {
                    do {
                        switch i % 5 {
                        case 0:
                            answer.set(fuzzer.mutate(page), headers: headers)
                            let start = [0, 1, 500, Int.max / 2].randomElement(using: &fuzzer.rng)!
                            let r = try await client.songsPage(start: start, end: start + 1000)
                            UISink.songs(r.songs)
                        case 1:
                            answer.set(fuzzer.mutate(page), headers: headers)
                            let r = try await client.songs(inLibrary: 1, pageSize: 50, maxPages: 4)
                            #expect(Set(r.songs.map(\.id)).count == r.songs.count)   // a repeated row is read once
                        case 2:
                            answer.set(fuzzer.mutate(page), headers: headers)
                            _ = (try await client.songs(recordingMBID: mbid, inLibrary: 1, under: "Artist/Album"))
                            _ = try await client.songs(recordingMBID: mbid, excludingLibrary: 2)
                        case 3:
                            answer.set(fuzzer.mutate(libraries))
                            _ = try await client.libraries()
                        default:
                            // A fresh client: its ping and sign-in read the fuzzed bodies.
                            let t = MockTransport()
                            let pingBody = fuzzer.rng.chance(0.5) ? fuzzer.mutate(ping) : ping
                            let loginBody = fuzzer.mutate(login)
                            t.stub(pathSuffix: "/rest/ping", body: pingBody)
                            t.stub(method: "POST", pathSuffix: "/auth/login", body: loginBody)
                            _ = SubsonicPing.isServerAnswer(pingBody)
                            let fresh = NavidromeClient(endpoint: ServerEndpoint(bases: [Self.base]),
                                                        credentials: NavidromeCredentials(username: "u", password: "p"), transport: t)
                            _ = try await fresh.connect()
                            _ = fresh.streamURL(songId: "s", maxBitRate: 320, format: "aac")
                        }
                    } catch {
                        ok = false
                        #expect(error is NavidromeError, "native case \(i % 5): \(error)")
                    }
                }
                stats.record(seconds: t, ok: ok)
            }
        }
        #expect(stats.decoded > 500 && stats.errors > 100)
        #expect(stats.slowest < 3, // ~0.1 s idle; quadratic blow-ups take many seconds; headroom for loaded machines
            "slowest case \(stats.slowest) s")
        #expect(total < 9, "sweep took \(total) s")
    }

    /// 50,000 songs in one answer: decoded, indexed and built into car rows in linear time.
    @Test func hugeAnswersStayLinear() async throws {
        let answer = Answer()
        let client = try await Self.connected(answer)
        let rows = (0..<50_000).map { i in
            #"{"id":"s\#(i % 49_000)","title":"Song \#(i)","artist":"Artist \#(i % 300)","albumId":"al\#(i % 4000)","album":"Album \#(i % 4000)","duration":\#(i % 2 == 0 ? "1e300" : "-1"),"libraryId":1,"genre":"Genre \#(i % 700)","trackNumber":\#(i),"discNumber":-\#(i)}"#
        }
        answer.set(Data("[\(rows.joined(separator: ","))]".utf8), headers: ["X-Total-Count": "50000"])
        let seconds = try await FuzzClock.seconds {
            let page = try await client.songsPage(start: 0, end: 50_000)
            #expect(page.songs.count == 50_000)
            UISink.songs(page.songs)
        }
        #expect(seconds < 9, "50k songs took \(seconds) s")
        answer.set(Self.envelope(#""genres":{"genre":[\#((0..<50_000).map { #"{"value":"G\#($0 % 40_000) rock","songCount":9223372036854775807,"albumCount":\#($0)}"# }.joined(separator: ","))]}"#))
        let genreSeconds = try await FuzzClock.seconds { UISink.genres(try await client.genres()) }
        #expect(genreSeconds < 9, "50k genres took \(genreSeconds) s")
    }

    /// The Subsonic envelope's error shapes all surface as typed errors.
    @Test func errorEnvelopesAreTyped() async throws {
        let answer = Answer()
        let client = try await Self.connected(answer)
        for body in [#"{"subsonic-response":{"status":"failed","error":{"code":9223372036854775807,"message":null}}}"#,
                     #"{"subsonic-response":{"status":"failed","error":{"code":-1e300}}}"#,
                     #"{"subsonic-response":{"status":"failed"}}"#, #"{"subsonic-response":{"status":null}}"#,
                     #"{"subsonic-response":{"status":"ok","albumList2":{"album":[{"id":null}]}}}"#,
                     "<html>", "", "[", #"{"subsonic-response":{"status":"ok","albumList2":"#] {
            answer.set(Data(body.utf8))
            await #expect(throws: NavidromeError.self) { _ = try await client.albumList(.newest, size: 1, offset: 0) }
        }
    }
}
