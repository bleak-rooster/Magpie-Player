import Foundation

/// Telling a Subsonic server's `rest/ping` answer apart from anything else that answers 200 (a router's
/// page, a captive portal, a reverse proxy's sign-in page). Security H2: credentials are only ever sent to
/// an address whose ping is a real Subsonic answer.
public enum SubsonicPing {
    /// Error codes a Subsonic server gives an unauthenticated ping: 10 missing parameter (Navidrome 0.64 answers
    /// a ping without `u` this way), 40–44 authentication. Anything else is not taken as a server.
    static let authErrorCodes: Set<Int> = [10, 40, 41, 42, 43, 44]

    private struct Envelope: Decodable {
        struct Body: Decodable {
            struct APIError: Decodable { let code: Int }
            let status: String
            let version: String?
            let error: APIError?
        }
        let response: Body
        enum CodingKeys: String, CodingKey { case response = "subsonic-response" }
    }

    /// True for a `subsonic-response` with `status: "ok"`, or with `status: "failed"`, a version, and an
    /// authentication error (the server wants credentials: it is a Subsonic server).
    public static func isServerAnswer(_ data: Data) -> Bool {
        guard let body = try? JSONDecoder().decode(Envelope.self, from: data).response else { return false }
        switch body.status {
        case "ok":
            return true
        case "failed":
            guard let version = body.version, !version.isEmpty, let code = body.error?.code else { return false }
            return authErrorCodes.contains(code)
        default:
            return false
        }
    }
}
