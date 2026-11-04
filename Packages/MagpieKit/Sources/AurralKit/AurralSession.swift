import Foundation
import MagpieCore

/// The Aurral user Magpie is signed in as (`POST /api/auth/login`'s `user`).
public struct AurralUser: Sendable, Equatable, Hashable, Codable {
    public var id: Int
    public var username: String
    public var role: String?
    /// Round 14 A1 (D80): what Aurral lets this user do (`permissions` on the login, `/api/auth/me` and the
    /// bootstrap). Nil when Aurral didn't say (a user saved before round 14 decodes with nil).
    public var permissions: AurralPermissions?

    public init(id: Int, username: String, role: String?, permissions: AurralPermissions? = nil) {
        self.id = id; self.username = username; self.role = role; self.permissions = permissions
    }

    /// Aurral shows an admin every user's flows (Magpie keeps only this user's: `AurralFlow.belongs(to:)`).
    public var isAdmin: Bool { role == "admin" }

    /// Round 14 (D80): Add flow (a Discover playlist into the user's flows) needs Aurral's `accessFlow`. An admin
    /// passes every check, as in Aurral's `hasPermission`; permissions Aurral didn't send fail closed.
    public var canAddFlow: Bool { isAdmin || permissions?.accessFlow == true }
    public var canAddArtist: Bool { isAdmin || permissions?.addArtist == true }
    public var canAddAlbum: Bool { isAdmin || permissions?.addAlbum == true }

    /// A user object (`{id, username, role, permissions}`); nil without an id or a name.
    static func decode(_ any: Any?) -> AurralUser? {
        guard let u = any as? [String: Any], let username = u.string("username"), username.count <= 200,
              let id = u.int("id") else { return nil }
        return AurralUser(id: id, username: username, role: u.string("role"),
                          permissions: u.dict("permissions").map(AurralPermissions.init(json:)))
    }

    /// `GET /api/auth/me`: `{user, expiresAt}`.
    public static func decodeMe(_ data: Data) throws -> AurralUser {
        guard let user = AurralUser.decode((object(data) as? [String: Any])?["user"]) else { throw AurralError.decoding }
        return user
    }
}

/// Round 14 A1 (D80): the Aurral permissions Magpie acts on (Aurral 2.13 `db/helpers/users.ts`; non-admin defaults
/// are addArtist and addAlbum on, accessFlow off). Only a JSON `true` counts.
public struct AurralPermissions: Sendable, Equatable, Hashable, Codable {
    public var accessFlow: Bool
    public var addArtist: Bool
    public var addAlbum: Bool

    public init(accessFlow: Bool, addArtist: Bool, addAlbum: Bool) {
        self.accessFlow = accessFlow; self.addArtist = addArtist; self.addAlbum = addAlbum
    }

    init(json p: [String: Any]) {
        self.init(accessFlow: p.bool("accessFlow") == true, addArtist: p.bool("addArtist") == true,
                  addAlbum: p.bool("addAlbum") == true)
    }
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
        return AurralLogin(token: token, expiresAt: expires, user: AurralUser(
            id: id, username: username, role: u["role"] as? String,
            permissions: (u["permissions"] as? [String: Any]).map(AurralPermissions.init(json:))))
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
    private let onRefused: @Sendable () -> Void
    private let now: @Sendable () -> Date
    /// Z1 fix M2: no login before this (15 minutes after a 429, 30 s after a failed one), with the error to give.
    private var backoff: (until: Date, error: Error)?
    /// The saved password was refused, or there is none: nothing more is tried until the owner signs in again.
    public private(set) var needsSignIn = false

    /// `onLogin` is told each new login (the app saves it to the Keychain); `onRefused`, once, that Aurral refused
    /// the password (the app forgets it and the token, for good: Z1 fix I1). Without a password or a login there is
    /// nothing to send: `needsSignIn` from the start, and no request.
    public init(username: String, password: String?, login: AurralLogin?,
                onLogin: @escaping @Sendable (AurralLogin) -> Void = { _ in },
                onRefused: @escaping @Sendable () -> Void = {},
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.username = username
        self.password = password
        self.login = login
        self.onLogin = onLogin
        self.onRefused = onRefused
        self.now = now
        self.needsSignIn = password == nil && login == nil
    }

    static let rateLimitBackoff: TimeInterval = 15 * 60
    static let failureBackoff: TimeInterval = 30

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
        if let backoff, now() < backoff.until { throw backoff.error }
        let username = username
        let task = Task { try await logIn(username, password) }
        renewing = task
        defer { renewing = nil }
        do {
            let fresh = try await task.value
            login = fresh
            backoff = nil
            onLogin(fresh)
            return fresh.token
        } catch AurralError.badLogin {
            needsSignIn = true
            login = nil
            onRefused()
            throw AurralError.signInNeeded
        } catch AurralError.rateLimited {
            backoff = (now().addingTimeInterval(Self.rateLimitBackoff), AurralError.rateLimited)
            throw AurralError.rateLimited
        } catch {
            backoff = (now().addingTimeInterval(Self.failureBackoff), error)
            throw error
        }
    }

    private func isExpired(_ login: AurralLogin) -> Bool {
        guard let expiresAt = login.expiresAt else { return false }
        return expiresAt.timeIntervalSince(now()) < 60
    }
}
