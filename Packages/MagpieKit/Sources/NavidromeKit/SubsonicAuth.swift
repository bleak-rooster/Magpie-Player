import CryptoKit
import Foundation

public struct NavidromeCredentials: Codable, Sendable {
    public var username: String
    public var password: String

    public init(username: String, password: String) {
        self.username = username
        self.password = password
    }
}

public struct LoginResult: Sendable {
    public var userId: String
    public var isAdmin: Bool
    public var username: String
    public var jwt: String
    public var subsonicToken: String
    public var subsonicSalt: String

    public init(userId: String, isAdmin: Bool, username: String, jwt: String,
                subsonicToken: String, subsonicSalt: String) {
        self.userId = userId; self.isAdmin = isAdmin; self.username = username
        self.jwt = jwt; self.subsonicToken = subsonicToken; self.subsonicSalt = subsonicSalt
    }
}

public enum NavidromeError: Error, Equatable, Sendable {
    case noReachableServer
    case badCredentials
    case http(status: Int)
    case api(code: Int, message: String)
    /// The address answered, but not with the API (e.g. a reverse proxy's HTML sign-in page).
    case unexpectedResponse
}

/// Subsonic token auth: `u, t, s, v, c, f`. The password is never sent.
enum SubsonicAuth {
    static let apiVersion = "1.16.1"

    static func md5Hex(_ s: String) -> String {
        Insecure.MD5.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func randomSalt(length: Int = 12) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        return String((0..<length).map { _ in alphabet.randomElement()! })
    }

    /// Uses the server-issued token/salt from login; falls back to `md5(password + salt)` when absent.
    static func queryItems(login: LoginResult, password: String, clientName: String) -> [URLQueryItem] {
        var token = login.subsonicToken
        var salt = login.subsonicSalt
        if token.isEmpty || salt.isEmpty {
            salt = randomSalt()
            token = md5Hex(password + salt)
        }
        return [
            URLQueryItem(name: "u", value: login.username),
            URLQueryItem(name: "t", value: token),
            URLQueryItem(name: "s", value: salt),
            URLQueryItem(name: "v", value: apiVersion),
            URLQueryItem(name: "c", value: clientName),
            URLQueryItem(name: "f", value: "json"),
        ]
    }
}
