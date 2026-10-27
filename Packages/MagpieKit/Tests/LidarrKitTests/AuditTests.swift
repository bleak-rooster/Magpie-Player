import Foundation
import Testing
import MagpieCore
import MagpieTestSupport
@testable import LidarrKit

@Suite struct AuditTests {
    @Test func parsesStatusAndRoots() async throws {
        let (client, _) = makeClient(auditTransport())
        let status = try await client.status()
        #expect(status.version == "3.2.0.5144")
        #expect(status.instanceName == "Lidarr")
        #expect(status.authenticationMethod == "forms")

        let roots = try await client.rootFolders()
        #expect(roots.map(\.path) == ["/music/library", "/music/samples"])
        #expect(roots[0].id == 1)
        #expect(roots[0].freeSpace == 733_184_000_000)

        let audit = await LidarrAudit.run(client)
        #expect(audit.reachable)
        #expect(audit.version == "3.2.0.5144")
        #expect(audit.authEnabled)
        #expect(audit.roots.count == 2)
        #expect(audit.healthIssues.count == 3)
        #expect(audit.healthIssues[0].source == "IndexerRssCheck")
        #expect(!audit.hasMagpieProfiles)
    }

    /// Fix 6.2a-2: the `magpie-find` tag is looked up by name, read-only (a setup made in M5 lacks its id).
    @Test func findTagLookedUpByName() async {
        let tags = json(#"[{"id":3,"label":"magpie"},{"id":9,"label":"magpie-find"},{"id":4,"label":"magpie-finder"}]"#)
        let (client, transport) = makeClient(auditTransport(["/tag": tags]))
        let audit = await LidarrAudit.run(client)
        #expect(audit.findTagId == 9)
        #expect(transport.requests.allSatisfy { ($0.httpMethod ?? "GET") == "GET" })
        let (none, _) = makeClient(auditTransport(["/tag": json(#"[{"id":3,"label":"magpie"}]"#)]))
        #expect(await LidarrAudit.run(none).findTagId == nil)
    }

    /// Task 6.2b: Keep moves a find to "Magpie Lossless", looked up by exact name (read-only).
    @Test func losslessProfileLookedUpByName() async {
        let profiles = json(#"[{"id":4,"name":"Magpie Fast Start"},{"id":5,"name":"Magpie Lossless"},{"id":6,"name":"magpie lossless"}]"#)
        let (client, transport) = makeClient(auditTransport(["/qualityprofile": profiles]))
        #expect(await LidarrAudit.run(client).losslessProfileId == 5)
        #expect(transport.requests.allSatisfy { ($0.httpMethod ?? "GET") == "GET" })
        let (none, _) = makeClient(auditTransport(["/qualityprofile": json(#"[{"id":2,"name":"Lossless"}]"#)]))
        #expect(await LidarrAudit.run(none).losslessProfileId == nil)
    }

    @Test func authNoneIsNotEnabled() async {
        let t = auditTransport(["/system/status": json(#"{"version":"3.2.0.1","authentication":"none"}"#)])
        let (client, _) = makeClient(t)
        let audit = await LidarrAudit.run(client)
        #expect(!audit.authEnabled)
    }

    @Test func magpieProfilesDetectedByExactNames() async {
        let quality = json(#"[{"id":1,"name":"Any"},{"id":9,"name":"Magpie Fast Start"},{"id":10,"name":"Magpie Lossless"}]"#)
        let metadata = json(#"[{"id":1,"name":"Standard"},{"id":5,"name":"Magpie Finds"},{"id":6,"name":"Magpie Albums+EPs"}]"#)
        let (client, _) = makeClient(auditTransport(["/qualityprofile": quality, "/metadataprofile": metadata]))
        #expect(await LidarrAudit.run(client).hasMagpieProfiles)

        // A look-alike name, or only some of the four, is not enough.
        let lookalike = json(#"[{"id":9,"name":"Magpie Standard"},{"id":10,"name":"Magpie Lossless"}]"#)
        let (partial, _) = makeClient(auditTransport(["/qualityprofile": lookalike, "/metadataprofile": metadata]))
        #expect(await LidarrAudit.run(partial).hasMagpieProfiles == false)
        let (noMetadata, _) = makeClient(auditTransport(["/qualityprofile": quality]))
        #expect(await LidarrAudit.run(noMetadata).hasMagpieProfiles == false)
    }

    @Test func pluginsMissingIsNotDetected() async throws {
        let t = MockTransport()
        t.stub(pathSuffix: "/system/plugins", status: 404, body: json(#"{"message":"NotFound"}"#))
        let (client, _) = makeClient(t)
        #expect(try await client.pluginsDetected() == false)

        let audit = await LidarrAudit.run(client)
        #expect(!audit.tubifarry)
    }

    @Test func pluginsEmptyArrayIsNotDetected_installedIsDetected() async throws {
        let (client, _) = makeClient(auditTransport())
        #expect(try await client.pluginsDetected() == false)

        let t = auditTransport(["/system/plugins": json(#"[{"name":"Tubifarry","owner":"TypNull","version":"1.0"}]"#)])
        let (withPlugin, _) = makeClient(t)
        #expect(try await withPlugin.pluginsDetected())
        #expect(await LidarrAudit.run(withPlugin).tubifarry)

        let t2 = auditTransport(["/system/plugins": json(#"[{"name":"Other"}]"#)])
        let (other, _) = makeClient(t2)
        #expect(try await other.pluginsDetected())
        #expect(await LidarrAudit.run(other).tubifarry == false)
    }

    @Test func recycleBinEmptyFlagged() async throws {
        let (client, _) = makeClient(auditTransport())
        #expect(try await client.recycleBin() == nil)
        #expect(await LidarrAudit.run(client).recycleBinSet == false)

        let t = auditTransport(["/config/mediamanagement": json(#"{"recycleBin":"/music/.recycle","recycleBinCleanupDays":7}"#)])
        let (set, _) = makeClient(t)
        #expect(try await set.recycleBin() == "/music/.recycle")
        #expect(await LidarrAudit.run(set).recycleBinSet)
    }

    @Test func unreachableServerAuditDoesNotThrow() async {
        let (client, _) = makeClient(MockTransport())   // everything 404
        let audit = await LidarrAudit.run(client)
        #expect(!audit.reachable)
        #expect(audit.roots.isEmpty)
        #expect(!audit.recycleBinSet)
    }

    @Test func queueProgressIsOneMinusSizeleftOverSize() async throws {
        let t = MockTransport()
        t.stub(pathSuffix: "/queue/details", body: Fixtures.data("queue-details"))
        let (client, _) = makeClient(t)
        let items = try await client.queueDetails(albumIds: [31, 32])
        #expect(items.count == 2)
        let first = items[0]
        #expect(first.albumId == 31)
        #expect(first.status == "downloading")
        #expect(first.trackedDownloadState == "downloading")
        #expect(first.timeleft == "00:04:12")
        #expect(first.progress == 0.75)               // 1 - 26214400 / 104857600
        #expect(items[1].progress == nil)              // size 0: not known yet
        #expect(items[1].statusMessages == ["Has unmatched tracks"])

        #expect(QueueItem(albumId: 1, size: 100, sizeleft: 0).progress == 1)
        #expect(QueueItem(albumId: 1, size: 100, sizeleft: 150).progress == 0)   // clamped

        let ids = t.requests.last.flatMap { URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.queryItems }
        #expect(ids?.filter { $0.name == "albumIds" }.compactMap(\.value) == ["31", "32"])
    }

    @Test func historyDownloadFailedIsWaiting() async throws {
        let t = MockTransport()
        t.stub(pathSuffix: "/history/since", body: Fixtures.data("history-since"))
        let (client, _) = makeClient(t)
        let events = try await client.historySince(Date(timeIntervalSince1970: 1_700_000_000))
        #expect(events.map(\.kind) == [.grabbed, .waiting, .waiting, .imported, .imported, .ignored, .other])
        #expect(events[1].eventType == "downloadFailed")
        #expect(events[0].date != nil)
        let date = t.requests.last.flatMap { URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.queryItems }?
            .first { $0.name == "date" }?.value
        #expect(date == "2023-11-14T22:13:20Z")
    }
}
