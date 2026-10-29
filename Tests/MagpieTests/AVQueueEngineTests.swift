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
        while Date() < deadline, !events.contains(where: { if case .failed(badId, _, _) = $0 { true } else { false } }) {
            try await Task.sleep(for: .milliseconds(50))
        }
        try await Task.sleep(for: .seconds(1.5))   // give any auto-advance time to surface

        #expect(events.contains { if case .failed(badId, _, _) = $0 { true } else { false } }, "\(events)")
        #expect(!events.contains(.itemChanged(goodId)), "must not move on to the next song: \(events)")

        // The user skips: the engine loads the next song even though it holds nothing after the halt.
        engine.next()
        try await Task.sleep(for: .milliseconds(300))
        collector.cancel()
        #expect(events.contains(.itemChanged(goodId)), "\(events)")
    }

    /// Task 13: only format, parse and decode errors mean a damaged file; a failure that may pass doesn't.
    @Test func undecodableClassification() {
        #expect(AVQueueEngine.isUndecodable(AVError(.fileFormatNotRecognized)))
        #expect(AVQueueEngine.isUndecodable(AVError(.decodeFailed)))
        #expect(AVQueueEngine.isUndecodable(AVError(.failedToParse)))
        let typ = NSError(domain: NSOSStatusErrorDomain, code: 1954115647)
        #expect(AVQueueEngine.isUndecodable(NSError(domain: AVFoundationErrorDomain, code: AVError.Code.unknown.rawValue,
                                                    userInfo: [NSUnderlyingErrorKey: typ])), "through the underlying error")
        let notAudio = NSError(domain: NSOSStatusErrorDomain, code: -12873)
        #expect(AVQueueEngine.isUndecodable(NSError(domain: AVFoundationErrorDomain, code: -11849,
                                                    userInfo: [NSUnderlyingErrorKey: notAudio])), "measured for non-audio bytes")
        #expect(!AVQueueEngine.isUndecodable(AVError(.failedToLoadMediaData)), "on its own it can be I/O")
        #expect(!AVQueueEngine.isUndecodable(AVError(.mediaServicesWereReset)))
        #expect(!AVQueueEngine.isUndecodable(URLError(.notConnectedToInternet)))
        #expect(!AVQueueEngine.isUndecodable(nil))
    }

    /// A file of bytes that aren't audio fails as undecodable through the real engine.
    @Test func garbageFileFailsAsUndecodable() async throws {
        let bad = FileManager.default.temporaryDirectory.appending(path: "garbage-\(UUID().uuidString).mp3")
        try Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 31) }).write(to: bad)
        defer { try? FileManager.default.removeItem(at: bad) }
        let engine = AVQueueEngine(activateSession: {})
        var events: [EngineEvent] = []
        let collector = Task { for await e in engine.events { events.append(e) } }
        let id = UUID()
        engine.setItems([(id, bad)], startAt: 0)
        engine.play()
        try await Self.waitUntil { events.contains { if case .failed(id, _, _) = $0 { true } else { false } } }
        collector.cancel()
        #expect(events.contains { if case .failed(id, _, true) = $0 { true } else { false } }, "\(events)")
    }

    /// Polls every 20 ms for up to 5 s.
    static func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(condition(), "timed out waiting")
    }

    @Test func setItemsKeepsEnqueuedNext() async throws {
        let w1 = try Self.silentWAV(), w2 = try Self.silentWAV(), w3 = try Self.silentWAV()
        defer { for w in [w1, w2, w3] { try? FileManager.default.removeItem(at: w) } }
        let a = UUID(), b = UUID(), c = UUID()
        let engine = AVQueueEngine()
        engine.setItems([(a, w1), (b, w2)], startAt: 0)
        engine.play()
        try await Self.waitUntil { engine.enqueuedItems.count == 2 }   // 2-s items: topUp enqueues at once
        engine.setItems([(a, w1), (b, w3)], startAt: 0)
        #expect(engine.enqueuedItems.map(\.url) == [w1, w2])
        engine.setItems([(a, w1), (c, w3)], startAt: 0)
        try await Self.waitUntil { engine.enqueuedItems.count == 2 }
        #expect(engine.enqueuedItems.map(\.url) == [w1, w3])
    }

    @Test func volumeBelowOneAppliesAnAudioMix() async throws {
        let w = try Self.silentWAV(), w2 = try Self.silentWAV(), a = UUID(), b = UUID()
        defer { for f in [w, w2] { try? FileManager.default.removeItem(at: f) } }
        let engine = AVQueueEngine()
        engine.setVolumes([a: 0.5])
        engine.setItems([(a, w)], startAt: 0)
        try await Self.waitUntil { engine.currentItemMixVolume != nil }
        #expect(abs(engine.currentItemMixVolume! - 0.5) < 0.001)
        engine.setVolumes([a: 0.25])
        try await Self.waitUntil { abs((engine.currentItemMixVolume ?? 0) - 0.25) < 0.001 }
        engine.setItems([(b, w2)], startAt: 0)
        try await Self.waitUntil { engine.enqueuedItems.first?.id == b }
        #expect(engine.currentItemMixVolume == nil, "unity gain: no mix")
    }

    /// Before the audio mix lands, the player volume carries the item's volume: no loud start.
    @Test func currentItemIsLevelledAtOnce() async throws {
        let w1 = try Self.silentWAV(), w2 = try Self.silentWAV(), a = UUID(), b = UUID()
        defer { for f in [w1, w2] { try? FileManager.default.removeItem(at: f) } }
        let engine = AVQueueEngine()
        engine.setVolumes([a: 0.5, b: 0.25])
        engine.setItems([(a, w1), (b, w2)], startAt: 0)
        #expect(abs(engine.currentItemEffectiveVolume - 0.5) < 0.001, "right after setItems")
        try await Self.waitUntil { engine.currentItemMixVolume != nil }
        #expect(abs(engine.currentItemEffectiveVolume - 0.5) < 0.001, "once the mix carries it")
        engine.next()
        #expect(engine.enqueuedItems.first?.id == b)
        #expect(abs(engine.currentItemEffectiveVolume - 0.25) < 0.001, "right after an advance")
        try await Self.waitUntil { engine.currentItemMixVolume != nil }
        #expect(abs(engine.currentItemEffectiveVolume - 0.25) < 0.001)
    }

    @Test func unityAfterAPendingVolumeLeavesNoMix() async throws {
        let w = try Self.silentWAV(), a = UUID()
        defer { try? FileManager.default.removeItem(at: w) }
        let engine = AVQueueEngine()
        engine.setItems([(a, w)], startAt: 0)
        engine.setVolumes([a: 0.5])
        engine.setVolumes([a: 1])
        try await Task.sleep(for: .milliseconds(500))   // let the 0.5 load finish: it must not land
        #expect(engine.currentItemMixVolume == nil)
        #expect(engine.currentItemEffectiveVolume == 1)
    }

    @Test func keptNextItemTakesANewVolume() async throws {
        let w1 = try Self.silentWAV(), w2 = try Self.silentWAV(), a = UUID(), b = UUID()
        defer { for f in [w1, w2] { try? FileManager.default.removeItem(at: f) } }
        let engine = AVQueueEngine()
        engine.setItems([(a, w1), (b, w2)], startAt: 0)
        engine.play()
        try await Self.waitUntil { engine.enqueuedItems.count == 2 }
        engine.pause()
        engine.setVolumes([b: 0.25])
        engine.setItems([(a, w1), (b, w2)], startAt: 0)
        #expect(engine.enqueuedItems.count == 2, "b is kept, not re-enqueued")
        engine.next()
        #expect(abs(engine.currentItemEffectiveVolume - 0.25) < 0.001)
        try await Self.waitUntil { abs((engine.currentItemMixVolume ?? 0) - 0.25) < 0.001 }
    }
}
