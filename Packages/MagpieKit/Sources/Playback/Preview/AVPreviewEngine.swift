import AVFoundation
import Foundation
import MagpieCore

/// Round 14 A2 (D86, D88), A7 (D110): the preview engine. Plays the clip Aurral sent (`PreviewResolver` fetched it into
/// memory through Aurral; the phone never contacts Deezer) with an `AVAudioPlayer` of its own, never the main
/// `AVQueueEngine`. The bytes are never written to disk and go with Stop.
///
/// On iOS it shares the app's `.playback` audio session (the main engine set its category). It activates the session before
/// playing (off the main thread, as the main engine does), and follows interruptions: a call pauses the clip, and the
/// system's resumption recommendation is passed on.
@MainActor
public final class AVPreviewEngine: PreviewEngine {
    public let events: AsyncStream<PreviewEngineEvent>
    private let continuation: AsyncStream<PreviewEngineEvent>.Continuation
    private var player: AVAudioPlayer?
    private var delegate: Delegate?
    private var token = 0
    /// What the preview player last asked for (fix round 1): a pause during the fetch or the session activation holds,
    /// and a clip that finishes loading then only gets ready.
    private var wantsToPlay = false
    private var loading: Task<Void, Never>?
    private var ticker: Task<Void, Never>?
    private var notificationTokens: [NSObjectProtocol] = []

    public init() {
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

    public func load(_ clip: Data, token: Int, at: TimeInterval) {
        stop()
        self.token = token
        wantsToPlay = true
        loading = Task { [weak self] in
            do {
                await Self.activateSession()
                guard let self, !Task.isCancelled, self.token == token else { return }
                try self.start(clip, token: token, at: at)
            } catch is CancellationError {
                return
            } catch {
                // The category only.
                Log.logger("playback").error("preview failed: \(Log.category(of: error), privacy: .public)")
                guard let self, self.token == token else { return }
                self.continuation.yield(.failed(token: token))
            }
        }
    }

    public func pause() {
        wantsToPlay = false
        player?.pause()
        stopTicking()
    }

    public func resume() {
        wantsToPlay = true
        guard let player else { return }   // still loading: it plays when it is ready
        Task { [weak self] in
            await Self.activateSession()
            // A pause (or a stop, or another clip) that came during the activation wins.
            guard let self, self.player === player, self.wantsToPlay else { return }
            player.play()
            self.startTicking(token: self.token)
        }
    }

    public func stop() {
        token += 1
        wantsToPlay = false
        loading?.cancel()
        loading = nil
        stopTicking()
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
        self.player = player
        self.delegate = delegate
        if wantsToPlay {
            guard player.play() else { throw PreviewEngineError.wouldNotPlay }
            startTicking(token: token)
        }
        continuation.yield(.started(token: token))
    }

    private func stopTicking() {
        ticker?.cancel()
        ticker = nil
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
        // R21 (D166): iOS 27's inactive / resumption-recommendation pair, or iOS 26's interruption notification.
        notificationTokens += AudioSessionEvents.observeInterruptions(session, began: { [weak self] in
            self?.interrupted()
        }, ended: { [weak self] shouldResume in
            guard let self, self.isLive else { return }
            self.continuation.yield(.resumption(shouldResume: shouldResume))
        })
        notificationTokens.append(center.addObserver(forName: AVAudioSession.routeChangeNotification,
                                                     object: session, queue: .main) { [weak self] note in
            let pauses = AudioSessionEvents.pausesPlayback(note.userInfo)
            MainActor.assumeIsolated {
                // Headphones unplugged: pause rather than play out of the speaker (as the main engine does). Not a call:
                // its own event, so no later recommendation resumes it.
                guard pauses, let self, self.isLive else { return }
                self.pause()
                self.continuation.yield(.routeLost)
            }
        })
        notificationTokens.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                                                     object: session, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                // Every AV object is dead: drop the player; the preview player loads the clip again.
                guard let self, self.isLive else { return }
                self.stop()
                self.continuation.yield(.mediaServicesReset)
            }
        })
    }

    /// A clip is loading or loaded.
    private var isLive: Bool { player != nil || loading != nil }

    /// A call (or another app) took the audio, while the clip plays or still loads.
    private func interrupted() {
        guard isLive, wantsToPlay else { return }
        wantsToPlay = false
        player?.pause()
        stopTicking()
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

/// Why the preview engine couldn't play a clip.
enum PreviewEngineError: Error { case wouldNotPlay }
