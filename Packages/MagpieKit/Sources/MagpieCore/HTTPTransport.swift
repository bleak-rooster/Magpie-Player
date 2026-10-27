import Foundation

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    public let timeout: TimeInterval
    private let session: URLSession

    /// Subsonic auth rides in the query string (`u`, `t`, `s`), so the default session is ephemeral
    /// and has no URLCache: nothing is written to disk.
    public static func defaultConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return config
    }

    public init(timeout: TimeInterval = 15,
                session: URLSession = SameOriginRedirects.session(configuration: URLSessionTransport.defaultConfiguration())) {
        self.timeout = timeout
        self.session = session
    }

    /// The configuration of the session in use (tests check it keeps no URLCache).
    var sessionConfiguration: URLSessionConfiguration { session.configuration }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var request = request
        request.timeoutInterval = timeout
        // The redirect policy is set per task too, so it holds whatever session was passed in (M1).
        let (data, response) = try await session.data(for: request, delegate: SameOriginRedirects.shared)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}
