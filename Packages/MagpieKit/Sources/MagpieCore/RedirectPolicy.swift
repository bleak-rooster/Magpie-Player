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

    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest) async -> URLRequest? {
        let original = task.originalRequest?.url ?? response.url
        guard Self.allows(from: original, to: request.url) else {
            Log.logger("network").error("redirect to another origin refused")
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
