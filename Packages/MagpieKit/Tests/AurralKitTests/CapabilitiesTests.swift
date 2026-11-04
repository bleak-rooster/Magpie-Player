import Foundation
import MagpieCore
import MagpieTestSupport
import Testing
@testable import AurralKit

/// Round 14 A1 (D79, D80): what this Aurral can do (`/api/health/bootstrap`) and what the signed-in user may do
/// (`/api/auth/me` `permissions`). Shapes from Aurral 2.13.0's `routes/health.ts` (`buildBootstrapPayload`),
/// `config/apiContract.ts`, `services/downloadSourceService.ts` and `routes/auth.ts`.
@Suite struct CapabilitiesTests {
    static let features213 = ["discover", "flows", "playlistCoverTemplates", "activity", "review", "trackDownloads",
                              "linkSearch", "downloadCancel", "shareImports", "trending", "flowAutoDownload"]

    static func bootstrap213(user: Bool = true, sources: Bool = true, configured: Bool = true) -> Data {
        var body: [String: Any] = [
            "status": "ok", "authRequired": true, "onboardingRequired": false, "appVersion": "2.13.0",
            "api": ["version": 1, "features": features213],
            "matcher": ["available": true, "policyVersion": "aurral-native-6"],
        ]
        if user {
            body["user"] = ["id": 2, "username": "jordan", "role": "user",
                            "permissions": ["accessFlow": true, "addArtist": true, "addAlbum": false]]
        }
        if sources {
            body["downloadSources"] = [
                "slskd": ["id": "slskd", "label": "Soulseek", "enabled": configured, "configured": configured, "priority": 2],
                "usenet": ["id": "usenet", "label": "Usenet", "enabled": false, "configured": false, "priority": 1,
                           "prowlarrConfigured": false],
                "deemix": ["id": "deemix", "label": "Deemix", "enabled": false, "configured": false, "priority": 3],
                "ytdlp": ["id": "ytdlp", "label": "yt-dlp", "enabled": configured, "configured": configured, "priority": 1],
            ]
        }
        return try! JSONSerialization.data(withJSONObject: body)
    }

    /// 2.10.0's bootstrap: no `api` contract at all.
    static let bootstrap210 = Data(#"{"status":"ok","authRequired":true,"appVersion":"2.10.0","onboardingRequired":false}"#.utf8)

    @Test func aurral213HasEverything() throws {
        let b = try AurralBootstrap.decode(Self.bootstrap213())
        #expect(b.appVersion == "2.13.0")
        #expect(b.apiVersion == 1)
        #expect(b.features.contains("trending") && b.features.contains("discover"))
        let c = b.capabilities
        #expect(c.recommendations && c.trending && c.editorialPlaylists && c.editorialLinks && c.artistPreview)
        #expect(c.search && c.releaseGroupTracks && c.discoverFeedback && c.flowDownload && c.trackResearch)
        #expect(c.playlistJobsById)
        #expect(c.anyDiscover)
    }

    /// 2.10 keeps today's behaviour: nothing new.
    @Test func aurral210HasNothingNew() throws {
        let b = try AurralBootstrap.decode(Self.bootstrap210)
        #expect(b.apiVersion == nil && b.features.isEmpty)
        #expect(b.capabilities == .none)
        #expect(!b.capabilities.anyDiscover)
        #expect(b.downloadSources == nil, "not said")
        #expect(b.hasDownloader == nil, "unknown")
    }

    /// Each capability follows its own feature flag; a 2.12 (no trending, shapes Magpie never checked) or an unknown
    /// API contract version gets none.
    @Test func featureFlagsAndVersionsGateEachCapability() {
        let noTrending = AurralCapabilities(appVersion: "2.13.1", apiVersion: 1,
                                            features: Set(Self.features213).subtracting(["trending"]))
        #expect(!noTrending.trending && noTrending.recommendations)
        let noDiscover = AurralCapabilities(appVersion: "2.13.0", apiVersion: 1, features: ["trending", "flows"])
        #expect(noDiscover.trending && !noDiscover.recommendations && !noDiscover.editorialPlaylists && !noDiscover.search)
        #expect(noDiscover.trackResearch && !noDiscover.flowDownload)
        #expect(AurralCapabilities(appVersion: "2.12.0", apiVersion: 1, features: Set(Self.features213)) == .none)
        #expect(AurralCapabilities(appVersion: "2.13.0", apiVersion: 2, features: Set(Self.features213)) == .none)
        #expect(AurralCapabilities(appVersion: nil, apiVersion: 1, features: Set(Self.features213)) == .none)
        #expect(AurralCapabilities(appVersion: "v2.14.0", apiVersion: 1, features: Set(Self.features213)).trending)
        #expect(AurralCapabilities(appVersion: "3.0.0", apiVersion: 1, features: Set(Self.features213)).trending)
    }

    @Test func downloadSourcesInPriorityOrder() throws {
        let b = try AurralBootstrap.decode(Self.bootstrap213())
        let sources = try #require(b.downloadSources)
        #expect(sources.map(\.id) == ["usenet", "ytdlp", "slskd", "deemix"])
        #expect(b.configuredDownloaders.map(\.id) == ["ytdlp", "slskd"])
        #expect(b.hasDownloader == true)
        let none = try AurralBootstrap.decode(Self.bootstrap213(configured: false))
        #expect(none.hasDownloader == false)
        let signedOut = try AurralBootstrap.decode(Self.bootstrap213(user: false, sources: false))
        #expect(signedOut.hasDownloader == nil && signedOut.user == nil)
    }

    @Test func bootstrapUserCarriesPermissions() throws {
        let user = try #require(try AurralBootstrap.decode(Self.bootstrap213()).user)
        #expect(user.username == "jordan" && !user.isAdmin)
        #expect(user.permissions == AurralPermissions(accessFlow: true, addArtist: true, addAlbum: false))
        #expect(user.canAddFlow)
    }

    @Test func junkBootstrapIsToleratedOrRefused() throws {
        #expect(throws: AurralError.decoding) { _ = try AurralBootstrap.decode(Data("<html>".utf8)) }
        #expect(throws: AurralError.decoding) { _ = try AurralBootstrap.decode(Data("[1,2]".utf8)) }
        let odd = try AurralBootstrap.decode(Data(#"""
            {"appVersion":7,"api":{"version":"1","features":["trending",3,null,{"x":1}]},
             "downloadSources":{"slskd":"yes","ytdlp":{"configured":"true","priority":"x"}},"user":{"id":true}}
            """#.utf8))
        #expect(odd.appVersion == nil && odd.apiVersion == nil && odd.features == ["trending"])
        #expect(odd.capabilities == .none)
        #expect(odd.user == nil)
        #expect(odd.downloadSources?.map(\.id) == ["ytdlp"])
        #expect(odd.hasDownloader == false, "a configured flag that isn't true is not configured")
    }

    // MARK: - Permissions (`/api/auth/me`)

    @Test func meDecodesPermissions() throws {
        let me = try AurralUser.decodeMe(Data(#"""
            {"user":{"id":3,"username":"kid","role":"user","permissions":{"accessFlow":false,"addArtist":true,
             "addAlbum":true,"deleteArtist":false}},"expiresAt":1790000000000}
            """#.utf8))
        #expect(me.id == 3 && me.username == "kid")
        #expect(me.permissions == AurralPermissions(accessFlow: false, addArtist: true, addAlbum: true))
        #expect(!me.canAddFlow && me.canAddArtist && me.canAddAlbum)
    }

    /// An admin passes every permission check (Aurral's `hasPermission`); unknown permissions fail closed.
    @Test func adminPassesUnknownFailsClosed() throws {
        let admin = AurralUser(id: 1, username: "root", role: "admin")
        #expect(admin.canAddFlow && admin.canAddArtist && admin.canAddAlbum)
        let unknown = AurralUser(id: 2, username: "u", role: "user")
        #expect(!unknown.canAddFlow && !unknown.canAddArtist && !unknown.canAddAlbum)
        let junk = try AurralUser.decodeMe(Data(#"{"user":{"id":4,"username":"j","permissions":{"accessFlow":"true","addArtist":1}}}"#.utf8))
        #expect(junk.permissions == AurralPermissions(accessFlow: false, addArtist: false, addAlbum: false))
        #expect(!junk.canAddFlow)
        #expect(throws: AurralError.decoding) { _ = try AurralUser.decodeMe(Data(#"{"user":null}"#.utf8)) }
    }

    /// A user saved by round 13 (no permissions) still decodes from the Keychain.
    @Test func savedUserWithoutPermissionsStillDecodes() throws {
        let old = Data(#"{"id":1,"username":"magpie","role":"admin"}"#.utf8)
        let user = try JSONDecoder().decode(AurralUser.self, from: old)
        #expect(user.permissions == nil && user.canAddFlow)
        let round = try JSONDecoder().decode(AurralUser.self, from: JSONEncoder().encode(
            AurralUser(id: 2, username: "x", role: "user", permissions: .init(accessFlow: true, addArtist: false, addAlbum: false))))
        #expect(round.canAddFlow && !round.canAddArtist)
    }

    /// The login's user carries its permissions too.
    @Test func loginCarriesPermissions() throws {
        let login = try AurralLogin.decode(Data(#"""
            {"token":"abc","expiresAt":1790000000000,"user":{"id":2,"username":"jordan","role":"user",
             "permissions":{"accessFlow":true,"addArtist":false,"addAlbum":false}}}
            """#.utf8))
        #expect(login.user.canAddFlow && !login.user.canAddArtist)
    }

    // MARK: - Over the wire (StubAurral)

    @Test func clientReadsBootstrapAndMeWithTheSession() async throws {
        let stub = StubAurral()
        stub.useAurral213()
        stub.addUser(id: 2, username: "jordan", password: "pw", role: "user")
        stub.setPermissions(.init(accessFlow: false, addArtist: true, addAlbum: true), for: "jordan")
        let session = AurralSession(username: "jordan", password: "pw", login: nil)
        let client = AurralClient(base: stub.base, session: session, transport: stub)
        let b = try await client.bootstrap()
        #expect(b.capabilities.trending && b.user?.username == "jordan")
        #expect(b.hasDownloader == true)
        let me = try await client.me()
        #expect(me.permissions?.accessFlow == false && !me.canAddFlow)
        #expect(stub.asked.suffix(2) == ["GET /api/health/bootstrap", "GET /api/auth/me"])
        #expect(stub.requests.suffix(2).allSatisfy { $0.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") == true })
        stub.setDownloadSources(configured: false)
        #expect(try await client.bootstrap().hasDownloader == false)
    }

    @Test func stubDefaultsTo210() async throws {
        let stub = StubAurral()
        let client = AurralClient(base: stub.base, session: stub.signedInSession(), transport: stub)
        #expect(try await client.bootstrap().capabilities == .none)
    }
}
