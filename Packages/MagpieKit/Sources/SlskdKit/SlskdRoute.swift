import Foundation

/// Round 23 (owner, 2026-11-07, D192): the only calls Magpie makes to slskd, the Soulseek client Lidarr's Tubifarry
/// plug-in downloads through. Researched in slskd's own source (github.com/slskd/slskd, 0.26.x `master`, API version 0):
/// - `GET  /api/v0/transfers/downloads` (`TransfersController.GetDownloadsAsync`): every download, grouped by user and
///   by the remote folder;
/// - `DELETE /api/v0/transfers/downloads/{username}/{id}?remove=true` (`CancelDownloadAsync`): cancels (a no-op for a
///   finished one) and removes the transfer record; `id` must be a GUID, `username` is URL-encoded (`[UrlEncoded]`);
/// - `GET  /api/v0/files/downloads/directories/{base64}` (`FilesController`): one folder of slskd's downloads folder,
///   named by its path relative to that folder, Base64 of its UTF-8 (`Base64Extensions.ToBase64`, standard alphabet),
///   URL-encoded;
/// - `DELETE /api/v0/files/downloads/directories/{base64}` and `DELETE /api/v0/files/downloads/files/{base64}`: delete
///   a folder (with what is in it) or one file inside slskd's downloads folder; slskd refuses (403) unless its
///   `remote_file_management` option is on, and refuses any path that isn't relative to the downloads folder.
/// The API key goes only in the `X-API-Key` header. Nothing else is ever called: no uploads, searches, shares, options,
/// users or the `incomplete` folder, and never `downloads/all/completed` (it would clear every user's records).
public enum SlskdRoute: Sendable, Equatable {
    case downloads
    case downloadsFolder(String)
    case removeTransfer(username: String, id: UUID)
    case deleteFile(folder: String, file: String)
    case deleteFolder(String)

    /// Reads are GETs; the three clean-up writes DELETE.
    public var method: String {
        switch self {
        case .downloads, .downloadsFolder: "GET"
        case .removeTransfer, .deleteFile, .deleteFolder: Self.deleteMethod
        }
    }

    // G1 allowlist: slskd clean-up (the three routes above; pinned in scripts/check-writes.sh)
    static let deleteMethod = "DELETE"

    /// The path below `api/v0/`, segment by segment (each percent-encoded when sent); nil when a name isn't safe.
    var segments: [String]? {
        switch self {
        case .downloads:
            return ["transfers", "downloads"]
        case .downloadsFolder(let folder):
            guard Self.isSafeName(folder) else { return nil }
            return ["files", "downloads", "directories", Self.base64(folder)]
        case .removeTransfer(let username, let id):
            guard Self.isSafeUsername(username) else { return nil }
            return ["transfers", "downloads", username, id.uuidString.lowercased()]
        case .deleteFile(let folder, let file):
            guard Self.isSafeName(folder), Self.isSafeName(file) else { return nil }
            return ["files", "downloads", "files", Self.base64(folder + "/" + file)]
        case .deleteFolder(let folder):
            guard Self.isSafeName(folder) else { return nil }
            return ["files", "downloads", "directories", Self.base64(folder)]
        }
    }

    var query: [URLQueryItem] {
        if case .removeTransfer = self { return [URLQueryItem(name: "remove", value: "true")] }
        return []
    }

    /// One folder or file name directly inside slskd's downloads folder: not empty, not only dots, not ending in a dot
    /// or a space, no separator
    /// (`/` or `\`), no control character, no `:` (a drive or stream on Windows), at most 255 bytes. A name that
    /// isn't safe is never sent, so a path can only ever name something one level (folder) or two levels (folder/file)
    /// inside the downloads folder.
    public static func isSafeName(_ s: String) -> Bool {
        guard !s.isEmpty, s != ".", s != "..", s.utf8.count <= 255, s.trimmingCharacters(in: .whitespaces) == s else {
            return false
        }
        // Fix round 1 M1: only dots, or a trailing dot or space: Windows strips them ("..." would name the root).
        guard !s.allSatisfy({ $0 == "." }), !s.hasSuffix("."), !s.hasSuffix(" ") else { return false }
        return !s.unicodeScalars.contains { $0 == "/" || $0 == "\\" || $0 == ":" || CharacterSet.controlCharacters.contains($0) }
    }

    /// A Soulseek user name as slskd lists it: not empty, at most 100 characters, no control character or separator.
    static func isSafeUsername(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 100 && s != "." && s != ".."
            && !s.unicodeScalars.contains { $0 == "/" || $0 == "\\" || CharacterSet.controlCharacters.contains($0) }
    }

    /// slskd's `FromBase64`: standard Base64 of the UTF-8 text.
    static func base64(_ s: String) -> String { Data(s.utf8).base64EncodedString() }

    /// Everything but RFC 3986's unreserved characters is percent-encoded (so a `/`, `+` or `=` of Base64 or a user
    /// name can't change the route; slskd's `[UrlEncoded]` decodes it).
    static func encode(_ segment: String) -> String {
        var allowed = CharacterSet.alphanumerics.intersection(CharacterSet(charactersIn: Unicode.Scalar(0)...Unicode.Scalar(127)))
        allowed.insert(charactersIn: "-._~")
        return segment.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    /// `<base>/api/v0/<segments>`: the base's own path (a reverse proxy's prefix) kept. Nil when a name isn't safe.
    func url(base: URL) -> URL? {
        guard let segments, var components = URLComponents(url: base, resolvingAgainstBaseURL: false),
              components.scheme == "http" || components.scheme == "https", components.host?.isEmpty == false else {
            return nil
        }
        var prefix = components.percentEncodedPath
        while prefix.hasSuffix("/") { prefix.removeLast() }
        components.percentEncodedPath = prefix + "/api/v0/" + segments.map(Self.encode).joined(separator: "/")
        components.percentEncodedQuery = query.isEmpty ? nil : query.map { "\($0.name)=\($0.value ?? "")" }.joined(separator: "&")
        components.fragment = nil
        return components.url
    }
}
