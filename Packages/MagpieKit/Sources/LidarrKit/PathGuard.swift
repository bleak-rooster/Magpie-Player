import Foundation

/// Why a candidate Finds root can't be used (G2).
public enum RootValidation: Sendable, Equatable {
    case ok
    /// The same folder as another root (after standardising, ignoring case).
    case equalsOther
    /// Contains, or is contained by, another root. Nested roots are scanned twice and break confinement.
    case nested
    /// Not an absolute POSIX path (empty, relative, or a Windows path, which Magpie doesn't confine).
    case notAbsolute
}

/// G2 / G3.3: path confinement for the Finds root. Deletes and moves only touch paths for which `isInside`
/// is true.
///
/// Comparison is on the strings Lidarr and Navidrome report, never on this device's filesystem: paths are
/// standardised lexically (`.` and empty components dropped, trailing `/` stripped) and compared component by
/// component, so `/music/samples-old` is not inside `/music/samples`.
///
/// `isInside` refuses any path with a `..` component instead of resolving it: if `Artist` is a link on the
/// server, `Artist/..` is not its lexical parent. Lidarr never reports `..` in artist or track paths, so
/// refusing costs nothing. (`validateRoot` and `PathMapping` do resolve `..`; there it only refuses more.)
///
/// Paths are split on the byte `/` (0x2F), never on Characters (security FL1): a combining mark right after `/`
/// makes the two one Character, so a Character split would miss that `/` (and a `..` before it). A component that
/// would fuse with its `/` that way (it starts with a combining or other extending scalar) is refused by `isInside`.
///
/// Accepting comparisons are byte-exact (UTF-8): Swift's `==` treats Unicode-equivalent spellings as equal,
/// but on ext4 `Fundé` (precomposed) and `Fundé` (decomposed) are different folders. Refusing comparisons
/// stay loose (canonical equivalence, case folded), which only refuses more.
///
/// Finds mode builds the guard case-sensitive (`caseInsensitive: false`): the server's volume can't be
/// detected, and case-sensitive fails safe.
///
/// Symlinks: Magpie can't see the server's filesystem, so it can't follow links. What it guarantees is that a
/// path passes only when it lies under the confirmed root's own spelling and inside no other root. A link that
/// Lidarr resolves (reporting the target path) is therefore refused, and a root that reaches another root only
/// through dot segments is refused by `validateRoot`. A link *inside* the Finds folder that Lidarr reports
/// unresolved can't be detected here; the other G3 preconditions (ledger, `magpie-find` tag) still apply.
public struct PathGuard: Sendable, Equatable {
    /// The confirmed Finds root, standardised. Nil when it isn't an absolute path.
    public let findsRoot: String?
    public let otherRoots: [String]
    /// Only true when the server's volume is known to be case-insensitive. Default false refuses more.
    public let caseInsensitive: Bool
    /// The configuration itself passed `validateRoot`. When not, `isInside` refuses everything.
    public let isValid: Bool

    public init(findsRoot: String, otherRoots: [String], caseInsensitive: Bool) {
        self.findsRoot = Self.standardize(findsRoot)
        self.otherRoots = otherRoots
        self.caseInsensitive = caseInsensitive
        self.isValid = Self.validateRoot(findsRoot, others: otherRoots) == .ok
    }

    /// True when `path` is strictly below the Finds root (never the root itself), has no `..` component, and
    /// is inside no other root.
    public func isInside(_ path: String) -> Bool {
        guard isValid, !Self.byteComponents(path).contains(where: { Self.isDotDot($0) || Self.fusesWithSlash($0) }),
              let root = findsRoot.map(Self.components), let p = Self.standardize(path).map(Self.components)
        else { return false }
        guard p.count > root.count, Self.exactPrefix(p, root, foldCase: caseInsensitive) else { return false }
        // Defence in depth: never inside another root, whatever the case rules (refusing more is safe).
        return !otherRoots.contains { other in
            guard let o = Self.standardize(other).map(Self.components) else { return false }
            return Self.isBelowOrEqual(p, o, foldCase: true)
        }
    }

    /// G2: whether `root` may be the Finds root next to `others` (the other Lidarr roots, the main Navidrome
    /// library path, the main root). Compared ignoring case, since a collision on a case-insensitive volume
    /// must be refused too.
    public static func validateRoot(_ root: String, others: [String]) -> RootValidation {
        guard let r = standardize(root).map(components) else { return .notAbsolute }
        guard !r.isEmpty else { return .nested }   // `/` holds every other folder
        var result = RootValidation.ok
        for other in others {
            guard let o = standardize(other).map(components) else { continue }
            if isBelowOrEqual(r, o, foldCase: true), isBelowOrEqual(o, r, foldCase: true) { return .equalsOther }
            if isBelowOrEqual(r, o, foldCase: true) || isBelowOrEqual(o, r, foldCase: true) { result = .nested }
        }
        return result
    }

    /// G2 on fresh state: `finds` is one of Lidarr's `roots` (byte-exact after standardising) and still passes
    /// `validateRoot` against every other root and the main root.
    public static func findsRootStillValid(_ finds: String, main: String, roots: [String]) -> Bool {
        guard let f = standardize(finds).map({ Array($0.utf8) }) else { return false }
        let isFinds = { (p: String) in standardize(p).map { Array($0.utf8) == f } ?? false }
        guard roots.contains(where: isFinds) else { return false }
        return validateRoot(finds, others: roots.filter { !isFinds($0) } + [main]) == .ok
    }

    /// The lexical standard form of an absolute POSIX path (`/a/b`, `/` for the root); nil when not absolute.
    /// `..` above `/` stays at `/`, as on a real filesystem.
    public static func standardize(_ path: String) -> String? {
        guard path.utf8.first == UInt8(ascii: "/") else { return nil }
        var parts: [String] = []
        for part in byteComponents(path) {
            if Array(part.utf8) == [UInt8(ascii: ".")] { continue }
            if isDotDot(part) {
                if !parts.isEmpty { parts.removeLast() }
            } else {
                parts.append(part)
            }
        }
        return "/" + parts.joined(separator: "/")
    }

    static func components(_ standardized: String) -> [String] { byteComponents(standardized) }

    /// The non-empty components between `/` bytes (FL1: never a Character split).
    public static func byteComponents(_ path: String) -> [String] {
        path.utf8.split(separator: UInt8(ascii: "/"), omittingEmptySubsequences: true)
            .map { String(decoding: $0, as: UTF8.self) }
    }

    /// Exactly the bytes `..`.
    static func isDotDot(_ component: String) -> Bool { Array(component.utf8) == Array("..".utf8) }

    /// Starts with a scalar that joins the preceding `/` into one Character (a combining mark, ZWJ, an emoji
    /// modifier…): such a name is never one Magpie confines.
    static func fusesWithSlash(_ component: String) -> Bool { ("/" + component).count != component.count + 1 }

    /// Loose: Swift `==` (canonical equivalence). Use only where a match refuses.
    static func isBelowOrEqual(_ path: [String], _ root: [String], foldCase: Bool) -> Bool {
        guard path.count >= root.count else { return false }
        return zip(path, root).allSatisfy { foldCase ? $0.lowercased() == $1.lowercased() : $0 == $1 }
    }

    /// Strict: byte-for-byte UTF-8 (after lower-casing when `foldCase`). Use where a match accepts.
    static func exactPrefix(_ path: [String], _ root: [String], foldCase: Bool) -> Bool {
        guard path.count >= root.count else { return false }
        return zip(path, root).allSatisfy { a, b in
            foldCase ? Array(a.lowercased().utf8) == Array(b.lowercased().utf8) : Array(a.utf8) == Array(b.utf8)
        }
    }
}

/// B6: Lidarr and Navidrome may see the same folder under different paths (different container mounts).
/// Maps a Lidarr path to Navidrome's by swapping a whole-component prefix.
public struct PathMapping: Sendable, Equatable, Codable {
    public var lidarrPrefix: String
    public var navidromePrefix: String

    public init(lidarrPrefix: String, navidromePrefix: String) {
        self.lidarrPrefix = lidarrPrefix
        self.navidromePrefix = navidromePrefix
    }

    /// Navidrome's path for a Lidarr path; nil when the path isn't at or under `lidarrPrefix` (after
    /// standardising, so `..` can't climb out) or either prefix isn't absolute.
    public func toNavidrome(_ p: String) -> String? {
        guard let from = PathGuard.standardize(lidarrPrefix).map(PathGuard.components),
              let to = PathGuard.standardize(navidromePrefix).map(PathGuard.components),
              let path = PathGuard.standardize(p).map(PathGuard.components),
              PathGuard.exactPrefix(path, from, foldCase: false) else { return nil }
        return "/" + (to + path.dropFirst(from.count)).joined(separator: "/")
    }

    /// A mount-prefix guess for two paths to the same folder: drops the trailing components they share
    /// (`/srv/lidarr/samples`, `/srv/nd/samples` → `/srv/lidarr` → `/srv/nd`). Nil when either isn't absolute.
    public static func suggested(lidarr: String, navidrome: String) -> PathMapping? {
        guard var l = PathGuard.standardize(lidarr).map(PathGuard.components),
              var n = PathGuard.standardize(navidrome).map(PathGuard.components) else { return nil }
        while let a = l.last, let b = n.last, Array(a.utf8) == Array(b.utf8) {
            l.removeLast()
            n.removeLast()
        }
        return PathMapping(lidarrPrefix: "/" + l.joined(separator: "/"), navidromePrefix: "/" + n.joined(separator: "/"))
    }
}
