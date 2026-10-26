import Foundation

/// One server reachable at one or more base URLs (e.g. LAN address, then public address).
/// Base URLs may carry a path (`https://host/navidrome`); it is always preserved.
public struct ServerEndpoint: Codable, Sendable, Hashable {
    public var bases: [URL]

    public init(bases: [URL]) {
        self.bases = bases
    }

    /// Appends `path` to `base`'s own path (never `URL(string:relativeTo:)`, which drops the base path).
    public func url(_ base: URL, path: String, query: [URLQueryItem] = []) -> URL {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return base }
        let basePath = components.percentEncodedPath.trimmingSuffix("/")
        let extra = path.trimmingPrefix("/")
        components.percentEncodedPath = extra.isEmpty ? basePath : basePath + "/" + extra
        components.percentEncodedQuery = query.isEmpty ? nil : query.map { item in
            let name = Self.encode(item.name)
            guard let value = item.value else { return name }
            return name + "=" + Self.encode(value)
        }.joined(separator: "&")
        return components.url ?? base
    }

    private static let queryAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&=+;#")
        return set
    }()

    private static func encode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: queryAllowed) ?? s
    }
}

private extension String {
    func trimmingSuffix(_ s: Character) -> String {
        var out = self
        while out.last == s { out.removeLast() }
        return out
    }
    func trimmingPrefix(_ s: Character) -> String {
        String(drop(while: { $0 == s }))
    }
}

/// Returns the first base (in order) for which `probe` answers true.
public func firstReachable(_ endpoint: ServerEndpoint, probe: @Sendable (URL) async -> Bool) async -> URL? {
    for base in endpoint.bases where await probe(base) {
        return base
    }
    return nil
}
