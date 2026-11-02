import Foundation

/// Security M1: URLSession re-sends custom headers (`X-Api-Key`, `X-ND-Authorization`) and a 307's body (the
/// login password) to wherever a redirect points. This delegate follows a redirect only within the origin of
/// the task's original request (same scheme, host and port), so it never goes to another host and never
/// from https down to http. A refused redirect hands back the 3xx answer itself, which callers treat as an
/// error.
public final class SameOriginRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    public static let shared = SameOriginRedirects()

    /// A session that uses this policy for every task.
    public static func session(configuration: URLSessionConfiguration) -> URLSession {
        URLSession(configuration: configuration, delegate: shared, delegateQueue: nil)
    }

    /// Whether a redirect from `original` to `target` stays within `original`'s origin.
    public static func allows(from original: URL?, to target: URL?) -> Bool {
        guard let a = original.flatMap(Origin.init), let b = target.flatMap(Origin.init) else { return false }
        return a == b
    }

    /// Headers that carry a key or a login. A request with any of them is never redirected (round 12 M1).
    static let credentialHeaders = ["x-api-key", "x-nd-authorization", "authorization"]

    /// Round 12 M1: whether a redirect of `original` to `target` may be followed. Only a GET or HEAD with no
    /// key or auth header, and only within its origin. Every write (any other method) and every keyed request
    /// (Lidarr, Aurral, Navidrome's native API, ListenBrainz) is refused even on the same origin: its target
    /// never went through the write gate or Aurral's allow-list, and a same-origin 307 could re-point an
    /// allowed `DELETE /queue/7` at `/artist/5?deleteFiles=true`. Because keyed requests never follow, the
    /// gate and the allow-list are in effect re-run on every target: the only target ever sent is the one
    /// they checked.
    public static func allows(original: URLRequest?, to target: URL?) -> Bool {
        guard let original else { return false }
        let method = (original.httpMethod ?? "GET").uppercased()
        guard method == "GET" || method == "HEAD" else { return false }
        let headers = (original.allHTTPHeaderFields ?? [:]).keys.map { $0.lowercased() }
        guard !headers.contains(where: credentialHeaders.contains) else { return false }
        return allows(from: original.url, to: target)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest) async -> URLRequest? {
        guard Self.allows(original: task.originalRequest, to: request.url) else {
            Log.logger("network").error("redirect refused (another origin, a write, or a keyed request)")
            return nil
        }
        return request
    }

    private struct Origin: Equatable {
        var scheme: String
        var host: String
        var port: Int

        init?(_ url: URL) {
            guard let scheme = url.scheme?.lowercased(), let host = url.host()?.lowercased(), !host.isEmpty else {
                return nil
            }
            self.scheme = scheme
            self.host = host
            switch (url.port, scheme) {
            case (let p?, _): port = p
            case (nil, "https"): port = 443
            case (nil, "http"): port = 80
            default: return nil
            }
        }
    }
}
