import Foundation
import MagpieCore
import os

/// Round 23 (D192): an in-process slskd for tests. It answers exactly the routes `SlskdRoute` names, the way slskd
/// 0.26's controllers do (downloads grouped by user and remote folder; a folder by the Base64 of its relative name; a
/// delete of a file or folder 403 unless remote file management is on; a transfer delete needing a GUID). Any other
/// route answers 404 and is recorded, so a test can show nothing else was asked. It sends nothing anywhere.
/// G1 allowlist: stub slskd
public final class FakeSlskd: HTTPTransport, @unchecked Sendable {
    public struct Transfer: Sendable {
        public var id: UUID
        public var username: String
        public var directory: String
        public var file: String
        public var state: String
        public init(id: UUID = UUID(), username: String, directory: String, file: String, state: String = "Completed, Succeeded") {
            self.id = id; self.username = username; self.directory = directory; self.file = file; self.state = state
        }
        public var filename: String { directory + "\\" + file }
    }

    public struct State: Sendable {
        public var transfers: [Transfer] = []
        /// Folders directly inside the downloads folder: their files and subfolders.
        public var folders: [String: (files: [String], folders: [String])] = [:]
        public var remoteFileManagement = true
        public var apiKey = "test-slskd-key"
        public var down = false
        /// `DELETE` answers this status (a 5xx: nothing deleted) this many times.
        public var deleteFailures = 0
        /// What was deleted, in order: `file <folder>/<name>`, `folder <name>`, `record <id>`.
        public var deleted: [String] = []
        public init() {}
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())
    private let log = OSAllocatedUnfairLock(initialState: [URLRequest]())

    /// The verb of the three clean-up routes it answers. G1 allowlist: stub slskd
    static let deleteVerb = "DELETE"

    public init() {}

    public func with<T>(_ change: (inout State) -> T) -> T { lock.withLockUnchecked { change(&$0) } }

    public var requests: [URLRequest] { log.withLock { $0 } }
    /// Every request that isn't a GET. G1 allowlist: stub slskd
    public var writes: [URLRequest] { requests.filter { ($0.httpMethod ?? "GET") != "GET" } }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        log.withLock { $0.append(request) }
        let (status, body) = answer(request)
        let http = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!
        return (body, http)
    }

    private func json(_ object: Any) -> Data { (try? JSONSerialization.data(withJSONObject: object)) ?? Data() }

    private func answer(_ request: URLRequest) -> (Int, Data) {
        guard let url = request.url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return (400, Data()) }
        let state = with { $0 }
        if state.down { return (503, Data()) }
        guard request.value(forHTTPHeaderField: "X-API-Key") == state.apiKey else { return (401, Data()) }
        let raw = components.percentEncodedPath
        guard let range = raw.range(of: "/api/v0/") else { return (404, Data()) }
        let segments = raw[range.upperBound...].split(separator: "/").map { $0.removingPercentEncoding ?? "" }
        let method = request.httpMethod ?? "GET"
        let query = components.queryItems ?? []
        func decoded(_ s: String) -> String? { Data(base64Encoded: s).flatMap { String(data: $0, encoding: .utf8) } }

        switch (method, segments.count) {
        case ("GET", 2) where segments == ["transfers", "downloads"]:
            let byUser = Dictionary(grouping: state.transfers, by: \.username)
            return (200, json(byUser.map { user, transfers in
                ["username": user, "directories": Dictionary(grouping: transfers, by: \.directory).map { dir, files in
                    ["directory": dir, "fileCount": files.count, "files": files.map { t in
                        ["id": t.id.uuidString.lowercased(), "username": t.username, "direction": "Download",
                         "filename": t.filename, "size": 1000, "state": t.state] as [String: Any]
                    }] as [String: Any]
                }] as [String: Any]
            }))
        case ("GET", 4) where segments[0...2] == ["files", "downloads", "directories"]:
            guard let name = decoded(segments[3]), let folder = state.folders[name] else { return (404, Data()) }
            return (200, json(["name": name, "fullName": "/downloads/" + name,
                               "files": folder.files.map { ["name": $0, "fullName": "/downloads/\(name)/\($0)", "length": 1000] },
                               "directories": folder.folders.map { ["name": $0, "fullName": "/downloads/\(name)/\($0)"] }]))
        case (Self.deleteVerb, 4) where segments[0...2] == ["files", "downloads", "files"]:
            guard state.remoteFileManagement else { return (403, Data()) }
            if failing() { return (500, Data()) }
            guard let path = decoded(segments[3]) else { return (400, Data()) }
            let parts = path.split(separator: "/").map(String.init)
            guard parts.count == 2, !parts.contains(".."), state.folders[parts[0]]?.files.contains(parts[1]) == true else {
                return (404, Data())
            }
            with { s in
                s.folders[parts[0]]?.files.removeAll { $0 == parts[1] }
                s.deleted.append("file \(path)")
            }
            return (204, Data())
        case (Self.deleteVerb, 4) where segments[0...2] == ["files", "downloads", "directories"]:
            guard state.remoteFileManagement else { return (403, Data()) }
            if failing() { return (500, Data()) }
            guard let name = decoded(segments[3]), state.folders[name] != nil else { return (404, Data()) }
            with { s in
                s.folders[name] = nil
                s.deleted.append("folder \(name)")
            }
            return (204, Data())
        case (Self.deleteVerb, 4) where segments[0...1] == ["transfers", "downloads"]:
            guard let id = UUID(uuidString: segments[3]) else { return (400, Data()) }
            guard query.contains(where: { $0.name == "remove" && $0.value == "true" }) else { return (204, Data()) }
            if failing() { return (500, Data()) }
            let found = with { s -> Bool in
                guard s.transfers.contains(where: { $0.id == id && $0.username == segments[2] }) else { return false }
                s.transfers.removeAll { $0.id == id }
                s.deleted.append("record \(id.uuidString.lowercased())")
                return true
            }
            return found ? (204, Data()) : (404, Data())
        default:
            return (404, Data())
        }
    }

    private func failing() -> Bool {
        with { s in
            guard s.deleteFailures > 0 else { return false }
            s.deleteFailures -= 1
            return true
        }
    }
}
