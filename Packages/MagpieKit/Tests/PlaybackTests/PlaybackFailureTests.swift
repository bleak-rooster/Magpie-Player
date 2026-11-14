import AVFoundation
import Foundation
import Testing
@testable import Playback

/// Round 27 P (owner, 2026-11-14): what kind of failure stopped a song (D277). Network: the URL error codes, directly
/// or under AVFoundation's or CoreMedia's wrappers. Conversion: a server 5xx, or any other failure before 1 s played.
/// Undecodable: today's rule. Anything else: today's behaviour.
@Suite struct PlaybackFailureTests {
    static let networkCodes = [-1001, -1003, -1004, -1005, -1009, -1018, -1020, -1022]

    static func wrapped(_ inner: Error, domain: String = AVFoundationErrorDomain, code: Int = -11800) -> NSError {
        NSError(domain: domain, code: code, userInfo: [NSUnderlyingErrorKey: inner])
    }

    @Test(arguments: networkCodes)
    func failure_networkCodesAreNetwork(_ code: Int) {
        let error = NSError(domain: NSURLErrorDomain, code: code)
        #expect(PlaybackFailure.kind(of: error, playedFor: 0) == .network, "before a second too: the network says so")
        #expect(PlaybackFailure.kind(of: error, playedFor: 95) == .network)
        #expect(PlaybackFailure.kind(of: URLError(URLError.Code(rawValue: code)), playedFor: 95) == .network)
    }

    @Test(arguments: [-11800, -11819, -11847, -11850, -11866])
    func failure_underlyingURLErrorInsideAVErrorIsNetwork(_ avCode: Int) {
        let lost = URLError(.networkConnectionLost)
        #expect(PlaybackFailure.kind(of: Self.wrapped(lost, code: avCode), playedFor: 60) == .network)
        let viaCoreMedia = Self.wrapped(Self.wrapped(lost, domain: "CoreMediaErrorDomain", code: -12938), code: avCode)
        #expect(PlaybackFailure.kind(of: viaCoreMedia, playedFor: 60) == .network, "through CoreMedia too")
        #expect(PlaybackFailure.kind(of: Self.wrapped(lost, domain: "CoreMediaErrorDomain", code: -12645), playedFor: 60)
                == .network)
    }

    @Test func failure_otherURLErrorsAreNotNetwork() {
        // A cancelled or a bad-URL request isn't a dropped connection: no retry on the same quality.
        #expect(PlaybackFailure.kind(of: URLError(.cancelled), playedFor: 60) == .other)
        #expect(PlaybackFailure.kind(of: URLError(.badURL), playedFor: 60) == .other)
        // A URL error under an AVFoundation code that isn't one of the wrappers falls to today's behaviour.
        #expect(PlaybackFailure.kind(of: Self.wrapped(URLError(.timedOut), code: -11999), playedFor: 60) == .other)
    }

    @Test func failure_beforeOneSecondIsConversion() {
        let odd = NSError(domain: AVFoundationErrorDomain, code: -11999)
        #expect(PlaybackFailure.kind(of: odd, playedFor: 0) == .conversion)
        #expect(PlaybackFailure.kind(of: odd, playedFor: 0.99) == .conversion)
        #expect(PlaybackFailure.kind(of: odd, playedFor: 1) == .other)
        #expect(PlaybackFailure.kind(of: nil, playedFor: 0.5) == .conversion, "no error at all, before a second")
    }

    @Test func failure_serverErrorIsConversionAtAnyTime() {
        let http = NSError(domain: "CoreMediaErrorDomain", code: -12939,
                           userInfo: [NSLocalizedDescriptionKey: "HTTP 500: Internal Server Error"])
        #expect(PlaybackFailure.kind(of: Self.wrapped(http), playedFor: 120) == .conversion)
        let notFound = NSError(domain: "CoreMediaErrorDomain", code: -12938,
                               userInfo: [NSLocalizedDescriptionKey: "HTTP 404: File Not Found"])
        #expect(PlaybackFailure.kind(of: Self.wrapped(notFound), playedFor: 120) == .other, "only a 5xx")
    }

    @Test func failure_undecodableIsTodaysRule() {
        #expect(PlaybackFailure.kind(of: AVError(.decodeFailed), playedFor: 0) == .undecodable)
        let typ = NSError(domain: NSOSStatusErrorDomain, code: 1954115647)
        #expect(PlaybackFailure.kind(of: Self.wrapped(typ), playedFor: 30) == .undecodable)
    }

    @Test func failure_unknownFallsBackToToday() {
        // Unknown codes after the first second are `.other`: the player keeps today's handling for them.
        for error in [NSError(domain: "SomeDomain", code: 7), NSError(domain: AVFoundationErrorDomain, code: -11819),
                      NSError(domain: "CoreMediaErrorDomain", code: -15628)] {
            #expect(PlaybackFailure.kind(of: error, playedFor: 42) == .other, "\(error)")
        }
        #expect(PlaybackFailure.kind(cause: .unknown, playedFor: 5) == .other)
        #expect(PlaybackFailure.kind(cause: .unknown, playedFor: .nan) == .other, "a non-number time is not 'early'")
    }

    @Test func failure_deepChainIsBounded() {
        // A cycle-free but very deep chain is walked only so far (no unbounded recursion on odd errors).
        var e: NSError = NSError(domain: NSURLErrorDomain, code: -1005)
        for _ in 0..<500 { e = Self.wrapped(e) }
        #expect(PlaybackFailure.kind(of: e, playedFor: 60) == .other)
    }
}
