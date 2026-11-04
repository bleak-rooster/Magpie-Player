import Foundation
import MagpieCore

// Round 14 A1: the Aurral 2.13 calls (docs/research/aurral-discover.md). Every one goes through `ok`, so through
// `AurralRoute`'s allow-list (route, verb and query names) and the session. Callers check `AurralCapabilities` first:
// on an Aurral without the route these answer `notFound`.

extension AurralClient {
    // MARK: - What this Aurral can do (D79, D80)

    /// `GET /api/health/bootstrap`, signed in (so it names the user's permissions and the download sources).
    public func bootstrap() async throws -> AurralBootstrap {
        try AurralBootstrap.decode(try await ok(method: "GET", path: "api/health/bootstrap"))
    }

    /// `GET /api/auth/me`: the signed-in user and their permissions.
    public func me() async throws -> AurralUser {
        try AurralUser.decodeMe(try await ok(method: "GET", path: "api/auth/me"))
    }
}
