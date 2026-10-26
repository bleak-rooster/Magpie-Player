import Foundation
import os

/// Thin wrapper over `os.Logger`. Requests are only ever printed in sanitised form.
public enum Log {
    public static let subsystem = "com.bleak-rooster.magpie"

    public static func logger(_ category: String) -> Logger {
        Logger(subsystem: subsystem, category: category)
    }

    /// Sanitised one-line description of a request (method, redacted URL, redacted headers).
    public static func describe(_ r: URLRequest) -> String {
        let method = r.httpMethod ?? "GET"
        let url = r.url.map(Redactor.sanitize) ?? "<no url>"
        let headers = Redactor.sanitize(headers: r.allHTTPHeaderFields ?? [:])
        let headerText = headers.keys.sorted().map { "\($0): \(headers[$0]!)" }.joined(separator: ", ")
        return headerText.isEmpty ? "\(method) \(url)" : "\(method) \(url) [\(headerText)]"
    }

    /// What kind of error it was, never its text: an `NSError`/`URLError` description can carry the failing
    /// URL (`NSErrorFailingURLStringKey`), credentials included (security M5). Safe for `privacy: .public`.
    public static func category(of error: Error) -> String {
        if let url = error as? URLError { return "URLError \(url.code.rawValue)" }
        let ns = error as NSError
        return "\(ns.domain) \(ns.code)"
    }

    public static func request(_ r: URLRequest, category: String = "network") {
        let text = describe(r)
        logger(category).debug("\(text, privacy: .public)")
    }
}
