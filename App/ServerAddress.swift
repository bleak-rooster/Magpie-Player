import Foundation

/// Turning what someone typed into a server address, and telling home-network addresses apart.
enum ServerAddress {
    /// What was typed, checked.
    enum Parsed: Equatable {
        case url(URL)
        /// Not a web address.
        case invalid
        /// `user:password@host`: credentials don't belong in an address (security M5: it would be saved,
        /// shown and logged).
        case containsCredentials
    }

    /// `192.168.1.20:4533` → `http://192.168.1.20:4533`; `music.example.com` → `https://music.example.com`
    /// (security H2: no scheme means https, unless the host is loopback or private). Nil when it can't be a
    /// web address or carries credentials.
    static func parse(_ text: String) -> URL? {
        if case .url(let url) = check(text) { return url }
        return nil
    }

    static func check(_ text: String) -> Parsed {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return .invalid }
        if !t.contains("://") {
            let host = URL(string: "http://" + t)
            t = (host.map(isPrivate) ?? false ? "http://" : "https://") + t
        }
        while t.hasSuffix("/") { t.removeLast() }
        guard let url = URL(string: t), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty else { return .invalid }
        if url.user != nil || url.password != nil { return .containsCredentials }
        return .url(url)
    }

    /// Private IPv4 ranges, link-local, `.local` and single-label names: places only reachable at home.
    static func isLocalNetwork(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        if host.hasSuffix(".local") { return true }
        let octets = host.split(separator: ".").compactMap { UInt8($0) }
        if octets.count == 4 {
            switch (octets[0], octets[1]) {
            case (10, _), (192, 168), (169, 254): return true
            case (172, let b) where (16...31).contains(b): return true
            default: return false
            }
        }
        return !host.contains(".") && !host.contains(":") && host != "localhost"
    }

    /// This device: `localhost`, 127.0.0.0/8, `::1`.
    static func isLoopback(_ url: URL) -> Bool {
        guard let host = url.host(percentEncoded: false)?.lowercased() else { return false }
        if host == "localhost" || host == "::1" || host == "[::1]" { return true }
        let octets = host.split(separator: ".").compactMap { UInt8($0) }
        return octets.count == 4 && octets[0] == 127
    }

    /// Never on the open internet: loopback, the home network (`isLocalNetwork`), carrier-grade NAT
    /// 100.64.0.0/10 (Tailscale), and IPv6 unique-local (fc00::/7) and link-local (fe80::/10).
    static func isPrivate(_ url: URL) -> Bool {
        if isLoopback(url) || isLocalNetwork(url) { return true }
        guard let host = url.host(percentEncoded: false)?.lowercased() else { return false }
        let octets = host.split(separator: ".").compactMap { UInt8($0) }
        if octets.count == 4, host.split(separator: ".").count == 4 {
            return octets[0] == 100 && (64...127).contains(octets[1])
        }
        let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if bare.contains(":"), let first = bare.split(separator: ":").first, let word = UInt16(first, radix: 16) {
            return (word & 0xFE00) == 0xFC00 || (word & 0xFFC0) == 0xFE80
        }
        return false
    }

    /// Security H2: credentials sent here travel unencrypted over the internet (plain http, public host).
    static func isUnencryptedPublic(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "http" && !isPrivate(url)
    }

    /// Who an address points at, for remembering consent: scheme, host and port.
    static func origin(_ url: URL) -> String {
        let scheme = url.scheme?.lowercased() ?? ""
        let host = url.host(percentEncoded: false)?.lowercased() ?? ""
        let port = url.port ?? (scheme == "https" ? 443 : 80)
        return "\(scheme)://\(host):\(port)"
    }
}

/// The owner agreed to send credentials over plain http to these addresses (security H2). Remembered per
/// address (origin) in the app's settings; not a secret.
struct PlainHTTPConsent {
    let defaults: UserDefaults
    static let key = "magpie.plainHTTPConsent"

    private var granted: Set<String> { Set(defaults.stringArray(forKey: Self.key) ?? []) }

    /// Credentials may go to `url`: it is encrypted, private, or the owner said yes to it.
    func allows(_ url: URL) -> Bool {
        !ServerAddress.isUnencryptedPublic(url) || granted.contains(ServerAddress.origin(url))
    }

    func grant(_ urls: [URL]) {
        let all = granted.union(urls.filter(ServerAddress.isUnencryptedPublic).map(ServerAddress.origin))
        defaults.set(all.sorted(), forKey: Self.key)
    }
}

/// Thrown before any credential is sent to these plain-http public addresses without the owner's consent.
struct PlainHTTPConsentRequired: Error, Equatable {
    let urls: [URL]
}
