import Foundation

/// Round 27 L (owner, 2026-11-14, Q1 yes): what LRCLIB found for a song: lines to show, or a note that it's an
/// instrumental (D311, D312).
public enum FoundLyrics: Sendable, Hashable {
    case lines(Lyrics)
    case instrumental
}

/// Round 27 L (owner, 2026-11-14): Find lyrics online, the one outside lyrics source (D311). The only file that names
/// LRCLIB's host (`scripts/check-writes.sh` pins it): https only, only `GET /api/get`, only the song's title, artist,
/// album and length in the query, `User-Agent: Magpie/<version>` and nothing else (no key, no cookie, no account, no
/// server name; a fixed `Accept-Language: en`), the answer capped at 512 KB, through `LrcLibTransport` (no redirect, no
/// cookie, nothing kept; L fix round 1, LL1). A 404 is none; a 429 is none and nothing more is sent until its
/// `Retry-After` has passed (at most an hour; a minute when it doesn't say). Any other failure is none. Which songs are
/// asked, and how often, is the app's (`AppModel+Lyrics.swift`: only with the switch on, only after the server had none,
/// once per song per session).
public actor LrcLib {
    public static let getURL = URL(string: "https://lrclib.net/api/get")!
    /// D312: LRCLIB's answer is read up to this size; a bigger one is none.
    public static let maxResponseBytes = 512 * 1024
    /// How long a 429 without a readable `Retry-After` holds LRCLIB off.
    public static let defaultBackoff: TimeInterval = 60
    /// The longest a 429 holds LRCLIB off.
    public static let maxBackoff: TimeInterval = 3600
    /// A title, artist or album longer than this is cut (the query stays small).
    static let maxFieldLength = 300

    /// No personal identifier: the app and its version only.
    public static func userAgent(version: String) -> String { "Magpie/\(version)" }

    /// The one request LRCLIB is ever sent; nil without a title or an artist. `duration` goes in whole seconds, only
    /// when 1–3600; the album only when it has words.
    public static func request(title: String, artist: String, album: String?, duration: TimeInterval?,
                               userAgent: String) -> URLRequest? {
        func field(_ s: String?) -> String? {
            guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
            return String(s.prefix(maxFieldLength))
        }
        guard let title = field(title), let artist = field(artist),
              var components = URLComponents(url: getURL, resolvingAgainstBaseURL: false) else { return nil }
        var items = [URLQueryItem(name: "track_name", value: title), URLQueryItem(name: "artist_name", value: artist)]
        if let album = field(album) { items.append(URLQueryItem(name: "album_name", value: album)) }
        if let duration, duration.isFinite {
            let whole = duration.rounded()
            if whole >= 1, whole <= 3600 { items.append(URLQueryItem(name: "duration", value: String(Int(whole)))) }
        }
        components.queryItems = items
        // A literal "+" would read as a space on the other side.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url, url.scheme == "https", url.host() == getURL.host(), url.path == getURL.path else {
            return nil
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        // L fix round 1 (LL2): a fixed language, so URLSession doesn't send the phone's.
        request.setValue("en", forHTTPHeaderField: "Accept-Language")
        return request
    }

    private let transport: HTTPTransport
    private let userAgent: String
    private let now: @Sendable () -> Date
    /// Set by a 429: nothing is sent before it.
    private var blockedUntil: Date?

    public init(transport: HTTPTransport, userAgent: String, now: @escaping @Sendable () -> Date = Date.init) {
        self.transport = transport; self.userAgent = userAgent; self.now = now
    }

    /// LRCLIB's lyrics for the song, or nil (not found, held off by a 429, or any failure).
    public func get(title: String, artist: String, album: String?, duration: TimeInterval?) async -> FoundLyrics? {
        if let blockedUntil, now() < blockedUntil { return nil }
        guard let request = Self.request(title: title, artist: artist, album: album, duration: duration,
                                         userAgent: userAgent) else { return nil }
        let data: Data, response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request, maxBytes: Self.maxResponseBytes)
        } catch {
            Log.logger("lyrics").info("online lyrics: no answer")
            return nil
        }
        switch response.statusCode {
        case 200:
            return Self.decode(data)
        case 429:
            blockedUntil = now().addingTimeInterval(Self.backoff(response.value(forHTTPHeaderField: "Retry-After"), now: now()))
            Log.logger("lyrics").info("online lyrics: asked to wait")
            return nil
        default:
            return nil
        }
    }

    /// `Retry-After` as seconds or an HTTP date, at most `maxBackoff`; `defaultBackoff` when it doesn't read or is past.
    static func backoff(_ header: String?, now: Date) -> TimeInterval {
        guard let header = header?.trimmingCharacters(in: .whitespaces), !header.isEmpty else { return defaultBackoff }
        if header.allSatisfy(\.isASCIIDigitCharacter) {
            guard header.count <= 6, let seconds = Int(header) else { return maxBackoff }
            return seconds > 0 ? min(TimeInterval(seconds), maxBackoff) : defaultBackoff
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        guard let date = formatter.date(from: header) else { return defaultBackoff }
        let wait = date.timeIntervalSince(now)
        return wait > 0 ? min(wait, maxBackoff) : defaultBackoff
    }

    /// `{syncedLyrics, plainLyrics, instrumental}`; anything else in the answer is ignored.
    static func decode(_ data: Data) -> FoundLyrics? {
        // L fix round 1 (LH1, crash hunt 4): measured before it's parsed; past `JSONNesting.limit` it's none.
        guard let object = JSONNesting.object(with: data) as? [String: Any] else { return nil }
        return LrcParser.answer(synced: object["syncedLyrics"] as? String, plain: object["plainLyrics"] as? String,
                                instrumental: object["instrumental"] as? Bool ?? false)
    }
}

/// Round 27 L (owner, 2026-11-14): LRCLIB's lyrics, read on the phone (D312). Synced lyrics first: LRC lines with one
/// or more `[mm:ss]`, `[mm:ss.x]`, `[mm:ss.xx]` or `[mm:ss.xxx]` stamps (minutes up to 999), sorted by time, `[offset:]`
/// applied (positive shows lines sooner) and every other tag skipped. Then plain lyrics, then the instrumental note. At
/// most 2,000 lines of 500 characters (and 1,000 Unicode scalars), trimmed, without control or format characters;
/// nothing that reads (no line with words) is none.
public enum LrcParser {
    public static let maxLines = 2_000
    public static let maxLineLength = 500
    public static let maxLineScalars = 1_000
    /// Raw lines looked at, at most (the answer is already capped at 512 KB).
    static let maxRawLines = 20_000

    public static func answer(synced: String?, plain: String?, instrumental: Bool) -> FoundLyrics? {
        if let synced, let lyrics = self.synced(synced) { return .lines(lyrics) }
        if let plain, let lyrics = self.plain(plain) { return .lines(lyrics) }
        return instrumental ? .instrumental : nil
    }

    public static func synced(_ text: String) -> Lyrics? {
        var stamped: [(start: TimeInterval, order: Int, text: String)] = []
        var offset: TimeInterval = 0
        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).prefix(maxRawLines) {
            var rest = Substring(raw).drop { $0.isWhitespace }
            var starts: [TimeInterval] = []
            while rest.first == "[", let close = rest.prefix(40).firstIndex(of: "]") {
                let inside = rest[rest.index(after: rest.startIndex)..<close]
                if let start = stamp(inside) {
                    starts.append(start)
                } else if let (key, value) = tag(inside) {
                    if key == "offset", let ms = offsetMilliseconds(value) { offset = TimeInterval(ms) / 1000 }
                } else {
                    break
                }
                rest = rest[rest.index(after: close)...]
            }
            guard !starts.isEmpty else { continue }   // a tag line, or words without a time
            let words = clean(rest)
            for start in starts { stamped.append((start, stamped.count, words)) }
        }
        let sorted = stamped.sorted { ($0.start, $0.order) < ($1.start, $1.order) }.prefix(maxLines)
        guard sorted.contains(where: { !$0.text.isEmpty }) else { return nil }
        return Lyrics(synced: true, lines: sorted.map { LyricLine(start: max(0, $0.start - offset), text: $0.text) })
    }

    public static func plain(_ text: String) -> Lyrics? {
        var lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .prefix(maxRawLines).map { clean($0) }
        while lines.first?.isEmpty == true { lines.removeFirst() }
        while lines.last?.isEmpty == true { lines.removeLast() }
        guard lines.contains(where: { !$0.isEmpty }) else { return nil }
        return Lyrics(synced: false, lines: lines.prefix(maxLines).map { LyricLine(text: $0) })
    }

    /// `m:ss`, `m:ss.f`, `m:ss.ff` or `m:ss.fff`: 1–3 digits of minutes, seconds under 60.
    static func stamp(_ s: Substring) -> TimeInterval? {
        let parts = s.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let minutes = digits(parts[0], 1...3) else { return nil }
        let secondParts = parts[1].split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(secondParts.count), let seconds = digits(secondParts[0], 2...2), seconds < 60 else { return nil }
        var fraction: TimeInterval = 0
        if secondParts.count == 2 {
            let f = secondParts[1]
            guard let value = digits(f, 1...3) else { return nil }
            fraction = TimeInterval(value) / pow(10, TimeInterval(f.count))
        }
        return TimeInterval(minutes * 60 + seconds) + fraction
    }

    /// `key:value` with a key of letters (`ar`, `ti`, `al`, `by`, `length`, `offset`…).
    static func tag(_ s: Substring) -> (String, Substring)? {
        guard let colon = s.firstIndex(of: ":") else { return nil }
        let key = s[..<colon]
        guard (1...16).contains(key.count), key.allSatisfy({ $0.isASCII && $0.isLetter }) else { return nil }
        return (key.lowercased(), s[s.index(after: colon)...])
    }

    /// `[offset:±ms]`, at most nine digits; anything else doesn't read.
    static func offsetMilliseconds(_ s: Substring) -> Int? {
        var value = s.trimmingCharacters(in: .whitespaces)[...]
        var sign = 1
        if value.first == "+" { value = value.dropFirst() } else if value.first == "-" { sign = -1; value = value.dropFirst() }
        return digits(value, 1...9).map { sign * $0 }
    }

    private static func digits(_ s: Substring, _ lengths: ClosedRange<Int>) -> Int? {
        guard lengths.contains(s.count), s.allSatisfy(\.isASCIIDigitCharacter) else { return nil }
        return Int(s)
    }

    /// Trimmed, without control characters, at most `maxLineLength` characters.
    /// L fix round 1 (LL5): format characters (bidi overrides, zero-width marks) go too, and at most `maxLineScalars`
    /// scalars are kept before the characters are counted.
    private static func clean(_ s: Substring) -> String {
        let kept = s.unicodeScalars.lazy
            .filter { $0.properties.generalCategory != .control && $0.properties.generalCategory != .format }
            .prefix(maxLineScalars)
        let text = String(String.UnicodeScalarView(kept)).trimmingCharacters(in: .whitespaces)
        return String(text.prefix(maxLineLength))
    }
}

private extension Character {
    var isASCIIDigitCharacter: Bool { isASCII && isNumber }
}
