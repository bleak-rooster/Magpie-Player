import Foundation
import MagpieCore

/// The Aurral user Magpie is signed in as (`POST /api/auth/login`'s `user`).
public struct AurralUser: Sendable, Equatable, Hashable, Codable {
    public var id: Int
    public var username: String
    public var role: String?

    public init(id: Int, username: String, role: String?) {
        self.id = id; self.username = username; self.role = role
    }

    /// Aurral shows an admin every user's flows (Magpie keeps only this user's: `AurralFlow.belongs(to:)`).
    public var isAdmin: Bool { role == "admin" }
}

/// Round 13 item 1: a signed-in Aurral session. Aurral 2.10.0 (`backend/routes/auth.js`, `config/session-helpers.js`)
/// answers a login with a random 64-hex token, kept in its database, sent as `Authorization: Bearer <token>`, and
/// valid until `expiresAt` (30 days by default, `SESSION_EXPIRY_HOURS`). There is no refresh route: a new login is
/// the only way to a new token. The token is a secret: never printed, logged or put in a URL.
public struct AurralLogin: Sendable, Equatable, Codable, CustomStringConvertible, CustomDebugStringConvertible,
                           CustomReflectable {
    public var token: String
    public var expiresAt: Date?
    public var user: AurralUser

    public init(token: String, expiresAt: Date?, user: AurralUser) {
        self.token = token; self.expiresAt = expiresAt; self.user = user
    }

    public var description: String { "AurralLogin(\(user.username))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["user": user.username]) }

    /// Aurral's login answer: `{token, expiresAt (ms since 1970), user{id, username, role, permissions}}`. Without a
    /// token or a user it isn't a login.
    static func decode(_ data: Data) throws -> AurralLogin {
        guard let o = JSONNesting.object(with: data) as? [String: Any],
              let token = o["token"] as? String, !token.isEmpty, token.count <= 4096,
              let u = o["user"] as? [String: Any], let username = u["username"] as? String, !username.isEmpty,
              let id = (u["id"] as? NSNumber).flatMap({ CFGetTypeID($0) == CFBooleanGetTypeID() ? nil : $0.intValue })
        else { throw AurralError.decoding }
        var expires: Date?
        if let ms = o["expiresAt"] as? NSNumber, CFGetTypeID(ms) != CFBooleanGetTypeID(), ms.doubleValue.isFinite,
           ms.doubleValue > 0, ms.doubleValue < 1e15 {
            expires = Date(timeIntervalSince1970: ms.doubleValue / 1000)
        } else if let text = o["expiresAt"] as? String {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            expires = iso.date(from: text) ?? ISO8601DateFormatter().date(from: text)
        }
        return AurralLogin(token: token, expiresAt: expires, user: AurralUser(id: id, username: username, role: u["role"] as? String))
    }
}

/// Holds the signed-in session for every `AurralClient` made from it, and logs in again when Aurral has forgotten
/// it: on a 401, or before a call once `expiresAt` has passed. Only with the password the owner let Magpie keep (in the
/// Keychain); one login at a time, shared by every call waiting on it (Aurral allows 10 logins in 15 minutes); and a
/// password Aurral refuses is never tried again (`needsSignIn`), so a changed password can't become a loop of logins.
public actor AurralSession: CustomDebugStringConvertible {
    public nonisolated let username: String
    private let password: String?
    private var login: AurralLogin?
    private var renewing: Task<AurralLogin, Error>?
    private let onLogin: @Sendable (AurralLogin) -> Void
    private let now: @Sendable () -> Date
    /// The saved password was refused, or there is none: nothing more is tried until the owner signs in again.
    public private(set) var needsSignIn = false

    /// `onLogin` is told each new login (the app saves it to the Keychain).
    public init(username: String, password: String?, login: AurralLogin?,
                onLogin: @escaping @Sendable (AurralLogin) -> Void = { _ in },
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.username = username
        self.password = password
        self.login = login
        self.onLogin = onLogin
        self.now = now
    }

    public nonisolated var debugDescription: String { "AurralSession(\(username))" }

    public var currentToken: String? { login?.token }
    public var user: AurralUser? { login?.user }

    /// A token to send: the current one while it's live, else a new login.
    func token(logIn: @escaping @Sendable (String, String) async throws -> AurralLogin) async throws -> String {
        if let login, !isExpired(login) { return login.token }
        return try await renew(after: login?.token, logIn: logIn)
    }

    /// Aurral refused `stale`: a new login, unless another call already got one (then that one).
    func renew(after stale: String?, logIn: @escaping @Sendable (String, String) async throws -> AurralLogin) async throws -> String {
        if let login, login.token != stale, !isExpired(login) { return login.token }
        if let renewing {
            do { return try await renewing.value.token } catch AurralError.badLogin { throw AurralError.signInNeeded }
        }
        guard !needsSignIn, let password else {
            needsSignIn = true
            throw AurralError.signInNeeded
        }
        let username = username
        let task = Task { try await logIn(username, password) }
        renewing = task
        defer { renewing = nil }
        do {
            let fresh = try await task.value
            login = fresh
            onLogin(fresh)
            return fresh.token
        } catch AurralError.badLogin {
            needsSignIn = true
            login = nil
            throw AurralError.signInNeeded
        }
    }

    private func isExpired(_ login: AurralLogin) -> Bool {
        guard let expiresAt = login.expiresAt else { return false }
        return expiresAt.timeIntervalSince(now()) < 60
    }
}
