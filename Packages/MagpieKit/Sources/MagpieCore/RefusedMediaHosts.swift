import Foundation

/// Round 14 A7 fix round 1 (owner, 2026-11-04, plan decision 11: no direct calls to Deezer or Apple from the phone,
/// whatever named the link). The only place these host names may be written in product code: `scripts/check-writes.sh`
/// bans them everywhere else and pins this list exactly. Outside art (`OutsideArtPolicy`: a Lidarr artist picture, a
/// redirect) on any of them, or a subdomain, is refused: the placeholder. Aurral's own pictures and previews go through
/// Aurral (D110, D111).
public enum RefusedMediaHosts {
    public static let domains = ["deezer.com", "dzcdn.net", "mzstatic.com", "apple.com"]

    /// The host is one of `domains` or under one (case-insensitive, a trailing dot ignored).
    public static func refuses(host: String) -> Bool {
        var name = host.lowercased()
        while name.hasSuffix(".") { name.removeLast() }
        return domains.contains { name == $0 || name.hasSuffix("." + $0) }
    }

    /// The URL's host is refused (a URL without a host is not, here: callers refuse those anyway).
    public static func refuses(_ url: URL) -> Bool {
        guard let host = url.host() else { return false }
        return refuses(host: host)
    }
}
