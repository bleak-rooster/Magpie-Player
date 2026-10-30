import Foundation
import MagpieCore
import MagpieTestSupport
import Testing
@testable import LidarrKit
@testable import ListenBrainzKit
@testable import Requests
@testable import Search

/// Crash hunt 4: seeded mutations of every LidarrKit, ListenBrainzKit and MusicBrainzClient answer. Decoding never
/// traps: each call throws its client's typed error or gives values that are sane and shown without trapping.
@Suite(.serialized) struct ExternalFuzzTests {
    static let mbid = MBID("c2272a15-9d25-4fd2-a0ae-0f4ab3c7f9d1")!

    /// Every value a raw document holds, read the ways provisioning reads them.
    static func walk(_ v: JSONValue) {
        _ = v.intValue; _ = v.stringValue; _ = v.boolValue
        switch v {
        case .array(let a): a.prefix(200).forEach(walk)
        case .object(let o): o.values.prefix(200).forEach(walk)
        default: break
        }
    }

    struct Call: Sendable {
        var name: String
        var seed: Data
        var run: @Sendable (LidarrClient) async throws -> Void
    }

    static func lidarr(_ name: String) -> Data { Fixture.data("lidarr", name) }

    static let calls: [Call] = [
        Call(name: "status", seed: lidarr("system-status")) { _ = try await $0.status() },
        Call(name: "health", seed: lidarr("health")) { _ = try await $0.health() },
        Call(name: "rootfolder", seed: lidarr("rootfolder")) {
            for f in try await $0.rootFolders() { #expect(f.freeSpace.map { $0 >= Int64.min } ?? true) }
        },
        Call(name: "qualityprofile", seed: lidarr("qualityprofile")) { _ = try await $0.qualityProfiles() },
        Call(name: "metadataprofile", seed: lidarr("metadataprofile")) { _ = try await $0.metadataProfiles() },
        Call(name: "tag", seed: lidarr("tag")) { _ = try await $0.tags() },
        Call(name: "plugins", seed: lidarr("system-plugins")) { _ = try await $0.pluginsDetected() },
        Call(name: "mediamanagement", seed: lidarr("config-mediamanagement")) { _ = try await $0.recycleBin() },
        Call(name: "artist lookup", seed: lidarr("artist-lookup")) {
            _ = try await $0.artistLookup(mbid: mbid)
            if let raw = try await $0.artistLookupJSON(mbid: mbid) {
                walk(raw)
                _ = try? JSONEncoder().encode(raw)
                _ = BodySummary.make(try? JSONEncoder().encode(raw), apiKey: "k", limit: 500)
            }
        },
        Call(name: "search", seed: lidarr("search")) {
            let hits = MergedSearch.Source.hits(from: try await $0.search(term: "q"))
            UISink.notYet(hits.albums.map { ExternalRecording(title: $0.title, artist: $0.artist, source: .lidarr) })
            _ = ArtistNotYet.excluding(hits.albums, library: [])
        },
        Call(name: "artists", seed: lidarr("artist")) { _ = try await $0.artists() },
        Call(name: "artist", seed: Data(String(decoding: lidarr("artist"), as: UTF8.self).drop { $0 != "{" }.dropLast(2).utf8)) {
            _ = try await $0.artist(id: 1)
        },
        Call(name: "albums", seed: lidarr("album-artistId")) {
            let albums = try await $0.albums(artistId: 1)
            for album in albums { #expect(album.duration.map { $0 > 0 && $0.isFinite } ?? true) }
            for choice in RequestRunner.BringInChoice.allCases {
                let option = RequestRunner.bringInOption(albums, choice: choice, songAlbums: Set(albums.compactMap(\.foreignAlbumId)),
                                                         skip: [], limit: 25)
                #expect((option?.albumIds.count ?? 0) <= 25)
                #expect(option?.duration.map { !$0.isNaN } ?? true)
            }
        },
        Call(name: "trackfiles", seed: lidarr("trackfile")) { _ = try await $0.trackFiles(artistId: 1) },
        Call(name: "queue", seed: lidarr("queue-details")) {
            for item in try await $0.queueDetails(albumIds: [1]) {
                if let p = item.progress { #expect((0...1).contains(p)) }
            }
        },
        Call(name: "history", seed: lidarr("history-since")) {
            for e in try await $0.historySince(Date(timeIntervalSince1970: 0)) { _ = e.kind }
        },
        Call(name: "command", seed: lidarr("command-id")) { _ = try await $0.command(id: 1) },
        Call(name: "commands", seed: lidarr("command")) { _ = try await $0.commands() },
        Call(name: "filesystem", seed: lidarr("filesystem")) {
            _ = try await $0.directories(in: "/music/")
            _ = try await $0.filesystemExists(path: "/music/library/")
        },
        Call(name: "schema", seed: lidarr("qualityprofile-schema")) { _ = try await $0.qualityProfiles() },
    ]

    @Test func lidarrEndpointsNeverTrap() async throws {
        let answer = Answer()
        let t = MockTransport()
        t.stub(pathSuffix: "") { _ in answer.response }
        let client = LidarrClient(base: URL(string: "https://music.example/lidarr")!, apiKey: "k", transport: t)
        var fuzzer = JSONFuzzer(seed: 0x11DA_44)
        var stats = SweepStats()
        let per = 5_000 / Self.calls.count + 1
        let total = await FuzzClock.seconds {
            for call in Self.calls {
                for _ in 0..<per {
                    let body = fuzzer.mutate(call.seed)
                    if ProcessInfo.processInfo.environment["HUNT_TRACE"] != nil {
                        try? body.write(to: FileManager.default.temporaryDirectory.appending(path: "hunt4-lidarr-last.json"))
                        FileHandle.standardError.write(Data("\(call.name) \(stats.cases)\n".utf8))
                    }
                    answer.set(body, status: fuzzer.rng.chance(0.03) ? 503 : 200)
                    var ok = true
                    let s = await FuzzClock.seconds {
                        do { try await call.run(client) } catch {
                            ok = false
                            #expect(error is LidarrError, "\(call.name): \(error)")
                        }
                    }
                    stats.record(seconds: s, ok: ok)
                }
            }
            // The audit reads several endpoints at once: each answers its own fuzzed body.
            for _ in 0..<200 {
                answer.set(fuzzer.mutate(Self.calls.randomElement(using: &fuzzer.rng)!.seed))
                _ = await LidarrAudit.run(client)
            }
        }
        #expect(stats.cases >= 5_000)
        #expect(stats.decoded > 500 && stats.errors > 100)
        #expect(stats.slowest < FuzzClock.caseBound, "slowest case \(stats.slowest) s")
        #expect(total < FuzzClock.sweepBackstop, "sweep took \(total) s")
    }

    @Test func listenBrainzAndMusicBrainzNeverTrap() async throws {
        let answer = Answer()
        let t = MockTransport()
        t.stub(method: "GET", pathSuffix: "") { _ in answer.response }
        let lb = ListenBrainzClient(transport: t, token: "tok", labsTimeout: 5, apiTimeout: 5,
                                    limiter: RateLimiter(perSecond: 1e9, sleep: { _ in }))
        let mb = MusicBrainzClient(transport: t, userAgent: "Magpie/test", limiter: RateLimiter(perSecond: 1e9, sleep: { _ in }))
        let labs = Fixture.data("listenbrainz", "labs-recording-search"), createdFor = Fixture.data("listenbrainz", "createdfor")
        let playlist = Fixture.data("listenbrainz", "playlist"), recording = Fixture.data("musicbrainz", "recording-c2272a15")
        let validate = Data(#"{"code":200,"message":"Token valid.","valid":true,"user_name":"magpie"}"#.utf8)
        var fuzzer = JSONFuzzer(seed: 0x1B_0B)
        var stats = SweepStats()
        let total = await FuzzClock.seconds {
            for i in 0..<5_200 {
                var ok = true
                let s = await FuzzClock.seconds {
                    do {
                        switch i % 5 {
                        case 0:
                            answer.set(fuzzer.mutate(labs))
                            let found = try await lb.searchRecordings("q")
                            #expect(found.count <= 15)
                            UISink.notYet(found)
                        case 1:
                            answer.set(fuzzer.mutate(createdFor))
                            let refs = try await lb.createdForPlaylists(user: "magpie")
                            #expect(MadeForYou.shelf(refs).count <= MadeForYou.shelfLimit)
                        case 2:
                            answer.set(fuzzer.mutate(playlist))
                            let tracks = try await lb.playlistTracks(Self.mbid)
                            #expect(tracks.allSatisfy { $0.duration.map { $0 > 0 && $0.isFinite } ?? true })
                            UISink.notYet(tracks)
                        case 3:
                            answer.set(fuzzer.mutate(validate))
                            _ = try await lb.tokenUser()
                        default:
                            answer.set(fuzzer.mutate(recording), status: fuzzer.rng.chance(0.05) ? 404 : 200)
                            let r = try await mb.recording(Self.mbid)
                            #expect(r.title.count <= 500 && r.isrcs.allSatisfy { $0.count <= 500 })
                            #expect(r.length.map { $0.isFinite && $0 >= 0 } ?? true)   // 5e-324 ms reads as 0 s
                        }
                    } catch {
                        ok = false
                        #expect(error is ListenBrainzError || error is MusicBrainzError, "case \(i % 5): \(error)")
                    }
                }
                stats.record(seconds: s, ok: ok)
            }
        }
        #expect(stats.decoded > 500 && stats.errors > 100)
        #expect(stats.slowest < FuzzClock.caseBound, "slowest case \(stats.slowest) s")
        #expect(total < FuzzClock.sweepBackstop, "sweep took \(total) s")
    }
}
