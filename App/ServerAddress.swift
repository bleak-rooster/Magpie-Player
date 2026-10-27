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

    /// The host as an IPv4 address: exactly four decimal labels, parsed by `inet_pton` (never a prefix of a
    /// longer name such as `10.0.0.1.evil.com`).
    static func ipv4(_ host: String) -> [UInt8]? {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        // A leading zero (`010`) is octal to the system resolver but decimal to `inet_pton`: not an address
        // we classify, so such a host is public.
        guard labels.count == 4, labels.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber)
                                                   && !($0.count > 1 && $0.first == "0") })
        else { return nil }
        var addr = in_addr()
        guard inet_pton(AF_INET, host, &addr) == 1 else { return nil }
        return withUnsafeBytes(of: &addr) { Array($0) }
    }

    /// The host as an IPv6 address (brackets allowed), parsed by `inet_pton`.
    static func ipv6(_ host: String) -> [UInt8]? {
        let bare = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
        guard bare.contains(":") else { return nil }
        var addr = in6_addr()
        guard inet_pton(AF_INET6, bare, &addr) == 1 else { return nil }
        return withUnsafeBytes(of: &addr) { Array($0) }
    }

    private static func host(_ url: URL) -> String? {
        url.host(percentEncoded: false)?.lowercased()
    }

    /// Private IPv4 ranges (10/8, 172.16/12, 192.168/16), link-local 169.254/16, `.local`, and single-label
    /// names that aren't numbers (`nas`): places only reachable at home. A single label made of digits
    /// (`134744072` is 8.8.8.8 to the resolver) is not a name, so it is not local.
    static func isLocalNetwork(_ url: URL) -> Bool {
        guard let host = host(url), !host.isEmpty else { return false }
        if let ip = ipv4(host) {
            switch (ip[0], ip[1]) {
            case (10, _), (192, 168), (169, 254): return true
            case (172, let b) where (16...31).contains(b): return true
            default: return false
            }
        }
        if ipv6(host) != nil { return false }
        if host.hasSuffix(".local") { return true }
        guard !host.contains("."), !host.contains(":"), host != "localhost" else { return false }
        // Numeric-looking single labels (decimal, hex `0x…`, octal) are addresses to the resolver.
        return !(host.first?.isNumber ?? true)
    }

    /// This device: `localhost`, 127.0.0.0/8, `::1`.
    static func isLoopback(_ url: URL) -> Bool {
        guard let host = host(url) else { return false }
        if host == "localhost" { return true }
        if let ip = ipv4(host) { return ip[0] == 127 }
        if let ip = ipv6(host) { return ip == [UInt8](repeating: 0, count: 15) + [1] }
        return false
    }

    /// Never on the open internet: loopback, the home network (`isLocalNetwork`), carrier-grade NAT
    /// 100.64.0.0/10 (Tailscale), and IPv6 unique-local (fc00::/7) and link-local (fe80::/10).
    static func isPrivate(_ url: URL) -> Bool {
        if isLoopback(url) || isLocalNetwork(url) { return true }
        guard let host = host(url) else { return false }
        if let ip = ipv4(host) { return ip[0] == 100 && (64...127).contains(ip[1]) }
        if let ip = ipv6(host) { return (ip[0] & 0xFE) == 0xFC || (ip[0] == 0xFE && (ip[1] & 0xC0) == 0x80) }
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
