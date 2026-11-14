import AVFoundation
import Foundation

/// Round 27 P (owner item 11, 2026-11-14): what kind of failure stopped a song (D277), so a dropped connection is no
/// longer taken for a server that couldn't convert it (which switched to the far heavier original, D278).
///
/// The URL error codes are Foundation's; the AVFoundation and CoreMedia wrappers they arrive under are UNCONFIRMED on a
/// device (taken from what AVFoundation documents and reports in the field). Anything not recognised falls to today's
/// handling: before the first second it counts as a conversion failure (the server's answer was no audio), after it as
/// `.other`, which the player treats as before.
public enum PlaybackFailure {
    public enum Kind: Sendable, Equatable {
        /// The connection dropped, timed out or went away: the same stream again from where it was.
        case network
        /// The server couldn't make the stream (a 5xx, or no audio before the first second): the original, once.
        case conversion
        /// The bytes aren't audio this phone can decode (`AVQueueEngine.isUndecodable`).
        case undecodable
        case other
    }

    /// What the error alone says, before how long the song had played. Reported by the engine for each failure.
    public enum Cause: Sendable, Equatable, Hashable {
        case network, serverError, undecodable, unknown
    }

    /// Timed out, host not found, couldn't connect, connection lost, not connected, roaming off, a call cut the data,
    /// the data link went away.
    static let networkCodes: Set<Int> = [-1001, -1003, -1004, -1005, -1009, -1018, -1020, -1022]
    /// The AVFoundation codes a URL error is looked for under (plan §5 P: unknown -11800, and -11819, -11847, -11850,
    /// -11866). Only the URL error underneath makes it a network failure; the code alone doesn't.
    static let avWrapperCodes: Set<Int> = [-11800, -11819, -11847, -11850, -11866]
    static let coreMediaDomain = "CoreMediaErrorDomain"
    /// A failure before this much has played (that isn't the network) is the server's conversion failing.
    public static let conversionWindow: TimeInterval = 1
    /// How deep a chain of underlying errors is followed.
    static let maxDepth = 8

    public static func kind(of error: (any Error)?, playedFor: TimeInterval) -> Kind {
        kind(cause: cause(of: error), playedFor: playedFor)
    }

    public static func kind(cause: Cause, playedFor: TimeInterval) -> Kind {
        switch cause {
        case .undecodable: .undecodable
        case .network: .network
        case .serverError: .conversion
        case .unknown: playedFor.isFinite && playedFor < conversionWindow ? .conversion : .other
        }
    }

    public static func cause(of error: (any Error)?) -> Cause {
        guard let error else { return .unknown }
        if AVQueueEngine.isUndecodable(error) { return .undecodable }
        if isNetwork(error as NSError, depth: 0) { return .network }
        if hasServerError(error as NSError, depth: 0) { return .serverError }
        return .unknown
    }

    /// A URL error of `networkCodes`, directly or under AVFoundation's wrappers and CoreMedia.
    private static func isNetwork(_ ns: NSError, depth: Int) -> Bool {
        guard depth < maxDepth else { return false }
        if ns.domain == NSURLErrorDomain { return networkCodes.contains(ns.code) }
        let wraps = (ns.domain == AVFoundationErrorDomain && avWrapperCodes.contains(ns.code)) || ns.domain == coreMediaDomain
        guard wraps, let inner = ns.userInfo[NSUnderlyingErrorKey] as? NSError else { return false }
        return isNetwork(inner, depth: depth + 1)
    }

    /// An HTTP 5xx anywhere in the chain: AVFoundation words it "HTTP 500: …" in the description (UNCONFIRMED per iOS
    /// version), or a status code in the user info.
    private static func hasServerError(_ ns: NSError, depth: Int) -> Bool {
        guard depth < maxDepth else { return false }
        for key in ["statusCode", "HTTPStatusCode", "NSHTTPStatusCode"] {
            if let code = ns.userInfo[key] as? Int, (500...599).contains(code) { return true }
        }
        let texts = [ns.localizedDescription, ns.userInfo[NSLocalizedFailureReasonErrorKey] as? String,
                     ns.userInfo[NSDebugDescriptionErrorKey] as? String].compactMap { $0 }
        if texts.contains(where: saysServerError) { return true }
        guard let inner = ns.userInfo[NSUnderlyingErrorKey] as? NSError else { return false }
        return hasServerError(inner, depth: depth + 1)
    }

    /// "HTTP 5" followed by two digits.
    private static func saysServerError(_ text: String) -> Bool {
        guard let range = text.range(of: "HTTP 5") else { return false }
        let rest = text[range.upperBound...].prefix(2)
        return rest.count == 2 && rest.allSatisfy(\.isASCII) && rest.allSatisfy(\.isNumber)
    }
}

/// Round 27 P (owner item 11, 2026-11-14): a converted stream that starts part-way (`timeOffset`, where the server
/// advertises `transcodeOffset`; D278, D281). The offset rides in the URL itself, so the player and the engine both know
/// where an item starts without other state.
public enum StreamOffset {
    static let name = "timeOffset"
    /// The longest offset honoured (a day): a damaged or hostile value can't become a huge position.
    static let maxSeconds = 86_400

    /// Where `url` starts, in whole seconds; 0 for a file, no offset, or a value that isn't a sane whole number.
    public static func seconds(in url: URL?) -> Int {
        guard let url, !url.isFileURL,
              let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .last(where: { $0.name == name })?.value,
              let n = Int(value), n > 0 else { return 0 }
        return min(n, maxSeconds)
    }

    /// `url` starting at `seconds` (any earlier offset replaced); nil for a file or a URL that can't be rebuilt.
    public static func url(_ url: URL, startingAt seconds: Int) -> URL? {
        guard !url.isFileURL, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        var items = (parts.queryItems ?? []).filter { $0.name != name }
        items.append(URLQueryItem(name: name, value: String(min(max(seconds, 0), maxSeconds))))
        parts.queryItems = items
        return parts.url
    }
}
