import Foundation

/// Turning what someone typed into a server address, and telling home-network addresses apart.
enum ServerAddress {
    /// `192.168.1.20:4533` → `http://192.168.1.20:4533`. Nil when it can't be a web address.
    static func parse(_ text: String) -> URL? {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if !t.contains("://") { t = "http://" + t }
        while t.hasSuffix("/") { t.removeLast() }
        guard let url = URL(string: t), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty else { return nil }
        return url
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
}
