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
/// standardised lexically (`.` and empty components dropped, `..` resolved, trailing `/` stripped) and
/// compared component by component, so `/music/samples-old` is not inside `/music/samples`.
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

    /// True when `path` is strictly below the Finds root (never the root itself) and inside no other root.
    public func isInside(_ path: String) -> Bool {
        guard isValid, let root = findsRoot.map(Self.components), let p = Self.standardize(path).map(Self.components)
        else { return false }
        guard Self.isStrictlyBelow(p, root, foldCase: caseInsensitive) else { return false }
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
        var result = RootValidation.ok
        for other in others {
            guard let o = standardize(other).map(components) else { continue }
            if isBelowOrEqual(r, o, foldCase: true), isBelowOrEqual(o, r, foldCase: true) { return .equalsOther }
            if isBelowOrEqual(r, o, foldCase: true) || isBelowOrEqual(o, r, foldCase: true) { result = .nested }
        }
        return result
    }

    /// The lexical standard form of an absolute POSIX path (`/a/b`, `/` for the root); nil when not absolute.
    /// `..` above `/` stays at `/`, as on a real filesystem.
    public static func standardize(_ path: String) -> String? {
        guard path.hasPrefix("/") else { return nil }
        var parts: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(part)
            }
        }
        return "/" + parts.joined(separator: "/")
    }

    static func components(_ standardized: String) -> [String] {
        standardized.split(separator: "/").map(String.init)
    }

    static func isBelowOrEqual(_ path: [String], _ root: [String], foldCase: Bool) -> Bool {
        guard path.count >= root.count else { return false }
        return zip(path, root).allSatisfy { foldCase ? $0.lowercased() == $1.lowercased() : $0 == $1 }
    }

    static func isStrictlyBelow(_ path: [String], _ root: [String], foldCase: Bool) -> Bool {
        path.count > root.count && isBelowOrEqual(path, root, foldCase: foldCase)
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
              PathGuard.isBelowOrEqual(path, from, foldCase: false) else { return nil }
        return "/" + (to + path.dropFirst(from.count)).joined(separator: "/")
    }
}
