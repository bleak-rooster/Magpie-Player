import AVFoundation
import Foundation
import MagpieCore

/// Round 14 A2 (D86, D88): the preview engine. Fetches the clip into memory (`PreviewClipFetcher`: https only, no cookie,
/// no cache) and plays it with an `AVAudioPlayer` of its own, never the main `AVQueueEngine`.
///
/// On iOS it shares the app's `.playback` audio session (the main engine set its category). It activates the session before
/// playing (off the main thread, as the main engine does), and follows interruptions: a call pauses the clip, and the
/// system's resumption recommendation is passed on.
@MainActor
public final class AVPreviewEngine: PreviewEngine {
    public let events: AsyncStream<PreviewEngineEvent>
    private let continuation: AsyncStream<PreviewEngineEvent>.Continuation
    private let fetcher: PreviewClipFetcher
    private var player: AVAudioPlayer?
    private var delegate: Delegate?
    private var token = 0
    private var loading: Task<Void, Never>?
    private var ticker: Task<Void, Never>?
    private var notificationTokens: [NSObjectProtocol] = []

    public init(fetcher: PreviewClipFetcher = PreviewClipFetcher()) {
        self.fetcher = fetcher
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(64))
        #if os(iOS)
        observeSession()
        #endif
    }

    isolated deinit {
        loading?.cancel()
        ticker?.cancel()
        for token in notificationTokens { NotificationCenter.default.removeObserver(token) }
    }

    public func load(_ url: URL, token: Int, at: TimeInterval) {
        stop()
        self.token = token
        let fetcher = self.fetcher
        loading = Task { [weak self] in
            do {
                let data = try await fetcher.fetch(url)
                try Task.checkCancellation()
                await Self.activateSession()
                guard let self, !Task.isCancelled, self.token == token else { return }
                try self.start(data, token: token, at: at)
            } catch is CancellationError {
                return
            } catch {
                // The category only: never the signed link.
                Log.logger("playback").error("preview failed: \(Log.category(of: error), privacy: .public)")
                guard let self, self.token == token else { return }
                self.continuation.yield(.failed(token: token))
            }
        }
    }

    public func pause() {
        player?.pause()
        ticker?.cancel()
    }

    public func resume() {
        guard let player else { return }
        Task { [weak self] in
            await Self.activateSession()
            guard let self, self.player === player else { return }
            player.play()
            self.startTicking(token: self.token)
        }
    }

    public func stop() {
        token += 1
        loading?.cancel()
        loading = nil
        ticker?.cancel()
        ticker = nil
        player?.stop()
        player = nil   // the clip's bytes go with it
        delegate = nil
    }

    // MARK: - Internals

    private func start(_ data: Data, token: Int, at: TimeInterval) throws {
        let player = try AVAudioPlayer(data: data)
        let delegate = Delegate(token: token, continuation: continuation)
        player.delegate = delegate
        player.prepareToPlay()
        if at > 0, at.isFinite, at < player.duration { player.currentTime = at }
        guard player.play() else { throw PreviewClipError.refused }
        self.player = player
        self.delegate = delegate
        continuation.yield(.started(token: token))
        startTicking(token: token)
    }

    /// Reports the position four times a second while the clip plays.
    private func startTicking(token: Int) {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let player = self.player, self.token == token else { return }
                let duration = player.duration
                self.continuation.yield(.time(token: token, player.currentTime,
                                              duration: duration.isFinite && duration > 0 ? duration : nil))
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private nonisolated static func activateSession() async {
        #if os(iOS)
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try AVAudioSession.sharedInstance().setActive(true)
                } catch {
                    Log.logger("playback").error("preview session failed: \(Log.category(of: error), privacy: .public)")
                }
                done.resume()
            }
        }
        #endif
    }

    #if os(iOS)
    private func observeSession() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        notificationTokens.append(center.addObserver(forName: AVAudioSession.didBecomeInactiveNotification,
                                                     object: session, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.interrupted() }
        })
        notificationTokens.append(center.addObserver(forName: AVAudioSession.resumptionRecommendationNotification,
                                                     object: session, queue: .main) { [weak self] note in
            let context = note.userInfo?[AVAudioSession.resumptionContextKey] as? AVAudioSession.ResumptionContext
            let shouldResume = context?.recommendation == .shouldResume
            MainActor.assumeIsolated {
                guard let self, self.player != nil else { return }
                self.continuation.yield(.resumption(shouldResume: shouldResume))
            }
        })
        notificationTokens.append(center.addObserver(forName: AVAudioSession.routeChangeNotification,
                                                     object: session, queue: .main) { [weak self] note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)
                .flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
            MainActor.assumeIsolated {
                // Headphones unplugged: pause rather than play out of the speaker (as the main engine does).
                guard reason == .oldDeviceUnavailable else { return }
                self?.interrupted()
            }
        })
    }

    private func interrupted() {
        guard let player, player.isPlaying || ticker != nil else { return }
        player.pause()
        ticker?.cancel()
        continuation.yield(.interrupted)
    }
    #endif

    /// AVAudioPlayer's callbacks: the end of the clip, or bytes that don't decode.
    private final class Delegate: NSObject, AVAudioPlayerDelegate, Sendable {
        let token: Int
        let continuation: AsyncStream<PreviewEngineEvent>.Continuation
        init(token: Int, continuation: AsyncStream<PreviewEngineEvent>.Continuation) {
            self.token = token
            self.continuation = continuation
        }
        func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
            continuation.yield(flag ? .ended(token: token) : .failed(token: token))
        }
        func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
            continuation.yield(.failed(token: token))
        }
    }
}
