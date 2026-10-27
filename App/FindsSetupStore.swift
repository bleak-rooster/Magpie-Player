import CryptoKit
import Foundation
import LidarrKit
import NavidromeKit

/// Finds mode's setup (M6): the owner-confirmed Finds folder (G2), the Navidrome library that is the same
/// folder, and the path mapping when Lidarr and Navidrome see it at different paths (B6). Local state only:
/// setting it up writes nothing to Lidarr (G5). Kept per Lidarr instance and Navidrome account, like
/// `LidarrSetup` (security M3), and forgotten on Lidarr disconnect and sign-out.
struct FindsSetup: Codable, Equatable, Sendable {
    var lidarrScope: String
    var navidromeScope: String
    /// "Use a Finds folder". Off by default; off means fallback mode (everything goes into the library).
    var useFindsFolder = false
    /// The Lidarr root folder the owner confirmed for Finds (Lidarr's path). Never inferred from a name.
    var findsRoot: String?
    /// The Navidrome library that is the Finds folder. Cleared whenever the root changes.
    var library: NavidromeLibrary?
    /// Lidarr → Navidrome paths, when they differ. Nil: the same paths.
    var mapping: PathMapping?

    /// The Finds folder as Navidrome sees it.
    var navidromeRoot: String? {
        guard let findsRoot else { return nil }
        return mapping.map { $0.toNavidrome(findsRoot) } ?? PathGuard.standardize(findsRoot)
    }

    /// Switched on, root confirmed, and a library that is the same folder.
    var isComplete: Bool {
        guard useFindsFolder, let library, let navidromeRoot else { return false }
        return PathGuard.standardize(library.path) == navidromeRoot
    }
}

/// Why a folder or library can't be the Finds folder. Settings copy (service names are allowed here).
enum FindsProblem: Error, Equatable {
    case notAbsolute
    case notARootFolder
    case sameAsOther
    case nested
    case isMainRoot
    case pathsDiffer
    case mappingMismatch
    case overlapsLibrary
    case mainRootFirst
    case mainRootNotMapped
    case notConnected

    var message: String {
        switch self {
        case .notAbsolute: "Magpie can only use a folder whose path starts with \u{201C}/\u{201D}."
        case .notARootFolder: "That isn't one of Lidarr's root folders."
        case .sameAsOther: "That's the same folder as another Lidarr root folder."
        case .nested: "That folder is inside another Lidarr root folder, or holds one. Finds need a folder of their own."
        case .isMainRoot: "New music already goes here. Finds need a folder of their own."
        case .pathsDiffer: "Navidrome sees that library at a different path. If it's the same folder, say how the paths match."
        case .mappingMismatch: "With these paths, the Finds folder doesn't land on that library."
        case .overlapsLibrary: "That library is your main library, sits inside another library, or holds one. Finds need a folder of their own."
        case .mainRootFirst: "Choose where new music goes first (Settings \u{203A} Lidarr)."
        case .mainRootNotMapped: "With these paths, Navidrome can't see where new music goes. Give the start of the path both servers share, such as /data/music and /music."
        case .notConnected: "Connect Lidarr and your music server first."
        }
    }
}

enum FindsCopy {
    static func confirmTitle(_ root: String) -> String { "Use \(root) for Finds?" }
    static let confirmMessage = "Magpie will only delete files it brought in here."
    static let recycleBinOff = "Lidarr's recycle bin is off, so finds you mark Not for me are deleted for good. "
        + "To be able to get them back, set a recycle bin in Lidarr \u{203A} Settings \u{203A} Media Management."
    static let off = "Off: new music goes straight into your library."
    static let notFinished = "Until this is finished, new music goes straight into your library."
    static let done = "Finds are set up."
    static let librariesForbidden = "Sign in to your music server with an admin account to choose the library."
    static let librariesFailed = "Couldn't read your music server's libraries. Try again."
}

/// One saved Finds setup per Lidarr instance and Navidrome account (`magpie.finds.<lidarr>.<navidrome>`).
struct FindsSetupStore {
    let defaults: UserDefaults
    private static let prefix = "magpie.finds."

    private static func key(_ lidarr: String, _ navidrome: String) -> String { "\(prefix)\(lidarr).\(navidrome)" }

    /// Identifies a Navidrome account: a hash of the first address and the user name.
    static func navidromeScope(base: URL, username: String) -> String {
        var text = base.absoluteString.lowercased()
        while text.hasSuffix("/") { text.removeLast() }
        let digest = SHA256.hash(data: Data("\(text)|\(username)".utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    func load(lidarrScope: String, navidromeScope: String) -> FindsSetup {
        guard let data = defaults.data(forKey: Self.key(lidarrScope, navidromeScope)),
              let saved = try? JSONDecoder().decode(FindsSetup.self, from: data),
              saved.lidarrScope == lidarrScope, saved.navidromeScope == navidromeScope else {
            return FindsSetup(lidarrScope: lidarrScope, navidromeScope: navidromeScope)
        }
        return saved
    }

    func save(_ setup: FindsSetup) {
        defaults.set(try? JSONEncoder().encode(setup), forKey: Self.key(setup.lidarrScope, setup.navidromeScope))
    }

    /// Forgets every Finds setup of a Lidarr (disconnect) or of a Navidrome account (sign-out).
    func clear(lidarrScope: String? = nil, navidromeScope: String? = nil) {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(Self.prefix) {
            let parts = key.dropFirst(Self.prefix.count).split(separator: ".").map(String.init)
            guard parts.count == 2 else { continue }
            if parts[0] == lidarrScope || parts[1] == navidromeScope { defaults.removeObject(forKey: key) }
        }
    }
}
