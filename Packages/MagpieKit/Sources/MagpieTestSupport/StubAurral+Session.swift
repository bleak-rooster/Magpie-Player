import AurralKit
import Foundation

public extension StubAurral {
    /// The default user (an admin), as Aurral's login names them.
    static let defaultUser = AurralUser(id: 1, username: StubAurral.defaultUsername, role: "admin")

    /// A session already signed in as the default user (a live token, no request sent), with the password saved so
    /// it can log in again.
    func signedInSession(password: String? = StubAurral.defaultPassword) -> AurralSession {
        AurralSession(username: Self.defaultUsername, password: password,
                      login: AurralLogin(token: issueToken(), expiresAt: nil, user: Self.defaultUser))
    }
}
