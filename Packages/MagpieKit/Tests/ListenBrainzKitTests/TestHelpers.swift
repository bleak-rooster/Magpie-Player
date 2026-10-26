import Foundation
import MagpieCore
import MagpieTestSupport
@testable import ListenBrainzKit

enum Fixtures {
    static func data(_ name: String, dir: String) -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: dir),
              let data = try? Data(contentsOf: url) else { fatalError("Missing fixture \(dir)/\(name).json") }
        return data
    }
}

func json(_ text: String) -> Data { Data(text.utf8) }

/// A clock and sleeper that never really wait: sleeping advances the fake clock and records the request.
final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var t: TimeInterval
    private var _sleeps: [TimeInterval] = []
    init(_ start: TimeInterval = 100) { t = start }
    var now: TimeInterval { lock.withLock { t } }
    var sleeps: [TimeInterval] { lock.withLock { _sleeps } }
    func advance(_ d: TimeInterval) { lock.withLock { t += d } }
    func sleep(_ d: TimeInterval) { lock.withLock { _sleeps.append(d); t += d } }

    func limiter(perSecond: Double = 1) -> RateLimiter {
        RateLimiter(perSecond: perSecond, now: { [self] in now }, sleep: { [self] in sleep($0) })
    }
}

/// A transport that never answers (cancellation-aware), for the labs timeout.
struct HangingTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await Task.sleep(for: .seconds(60))
        throw URLError(.timedOut)
    }
}
