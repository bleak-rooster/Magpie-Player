import Foundation

/// Strips credentials from anything that might be logged (spec §5).
public enum Redactor {
    public static let mask = "•••"
    static let queryKeys: Set<String> = ["u", "t", "s", "p", "apikey", "token", "password"]
    static let headerKeys: Set<String> = ["x-api-key", "x-nd-authorization", "authorization"]

    public static func sanitize(_ url: URL) -> String {
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return "<url>" }
        c.user = nil
        c.password = nil
        guard let items = c.percentEncodedQueryItems, !items.isEmpty else { return c.string ?? "<url>" }
        // Built by hand: URLComponents would percent-encode the mask.
        c.percentEncodedQueryItems = nil
        let query = items.map { item -> String in
            let name = item.name.removingPercentEncoding ?? item.name
            if item.value != nil, queryKeys.contains(name.lowercased()) { return "\(item.name)=\(mask)" }
            return item.value.map { "\(item.name)=\($0)" } ?? item.name
        }.joined(separator: "&")
        return (c.string ?? "<url>") + "?" + query
    }

    public static func sanitize(headers: [String: String]) -> [String: String] {
        headers.reduce(into: [:]) { out, pair in
            out[pair.key] = headerKeys.contains(pair.key.lowercased()) ? mask : pair.value
        }
    }
}
