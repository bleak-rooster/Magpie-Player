import AVFoundation
import Foundation
import Testing
import Playback

/// Runs the real AVQueuePlayer on the simulator. The bad URL points at a closed local port, so it
/// fails fast and deterministically.
@MainActor
@Suite struct AVQueueEngineTests {
    /// Writes a short silent 16-bit mono WAV and returns its file URL.
    static func silentWAV(seconds: Int = 2) throws -> URL {
        let rate = 8000, bytes = rate * 2 * seconds
        var d = Data()
        func u32(_ v: Int) { var x = UInt32(v).littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: Int) { var x = UInt16(v).littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(bytes); d.append(Data(count: bytes))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
        try d.write(to: url)
        return url
    }

    @Test(arguments: [false, true])
    func failedCurrentDoesNotAdvance(playFirst: Bool) async throws {
        let good = try Self.silentWAV()
        defer { try? FileManager.default.removeItem(at: good) }
        let bad = URL(string: "http://127.0.0.1:9/rest/stream?id=bad")!
        let badId = UUID(), goodId = UUID()
        let engine = AVQueueEngine()
        var events: [EngineEvent] = []
        let collector = Task { @MainActor in
            for await e in engine.events {
                if case .time = e { continue }
                events.append(e)
            }
        }
        if playFirst { engine.play() }
        engine.setItems([(badId, bad), (goodId, good)], startAt: 0)
        if !playFirst { engine.play() }

        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, !events.contains(where: { if case .failed(badId, _) = $0 { true } else { false } }) {
            try await Task.sleep(for: .milliseconds(50))
        }
        try await Task.sleep(for: .seconds(1.5))   // give any auto-advance time to surface

        #expect(events.contains { if case .failed(badId, _) = $0 { true } else { false } }, "\(events)")
        #expect(!events.contains(.itemChanged(goodId)), "must not move on to the next song: \(events)")

        // The user skips: the engine loads the next song even though it holds nothing after the halt.
        engine.next()
        try await Task.sleep(for: .milliseconds(300))
        collector.cancel()
        #expect(events.contains(.itemChanged(goodId)), "\(events)")
    }
}
