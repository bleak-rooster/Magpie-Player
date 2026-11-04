import DesignSystem
import Foundation
import MediaPlayer
import Playback
import SwiftUI
import Testing
import UIKit
@testable import Magpie

/// Round 14 A2 (D86, D89): the preview button's words and VoiceOver, the row and mini player at every text size in light
/// and dark, and the lock screen while a preview plays.
@MainActor
@Suite struct PreviewComponentsTests {
    @Test func theButtonSaysWhatItDoes() {
        #expect(PreviewStatus.ready.label == "Play preview")
        #expect(PreviewStatus.playing(progress: 0.5, secondsLeft: 15).label == "Stop preview")
        #expect(PreviewStatus.playing(progress: 0.5, secondsLeft: 15).accessibilityValue == "15 seconds left")
        #expect(PreviewStatus.playing(progress: 0.97, secondsLeft: 1).accessibilityValue == "1 second left")
        #expect(PreviewStatus.noPreview.label == "No preview available")
        #expect(PreviewStatus.unavailable.label == "Preview unavailable right now")
        #expect(PreviewStatus.loading.label == "Loading preview")
        // No service is named anywhere in the preview copy (design language §5).
        let copy = [PreviewStatus.ready, .loading, .playing(progress: 0, secondsLeft: 30), .noPreview, .unavailable].map(\.label)
            + [PreviewCopy.playPreviews, PreviewRow<EmptyView>.accessibilityLabel(title: "T", artist: "A", inLibrary: true)]
        for text in copy {
            for service in ["Aurral", "Deezer", "Lidarr", "Navidrome"] { #expect(!text.contains(service), "\(text)") }
        }
    }

    @Test func theRowSaysInYourLibrary() {
        #expect(PreviewRow<EmptyView>.accessibilityLabel(title: "Harbour Lights", artist: "Stub Arrows", inLibrary: true)
                == "Harbour Lights, Stub Arrows, in your library")
        #expect(PreviewRow<EmptyView>.accessibilityLabel(title: "Harbour Lights", artist: "Stub Arrows", inLibrary: false)
                == "Harbour Lights, Stub Arrows")
    }

    /// Every text size (accessibility sizes too), light and dark: the row, the button and the mini player lay out within
    /// a 375-point phone, and the button keeps a 44-point target.
    @Test func layOutAtEveryTextSizeInLightAndDark() {
        let sizes: [DynamicTypeSize] = [.xSmall, .large, .xxxLarge, .accessibility1, .accessibility5]
        for scheme in [ColorScheme.light, .dark] {
            for size in sizes {
                let row = PreviewRow(title: "A very long song title that goes on and on", artist: "Someone with a long name",
                                     inLibrary: true, status: .playing(progress: 0.3, secondsLeft: 21), onPreview: {}) {
                    Button("Listen to the full song") {}
                }
                let mini = PreviewMiniPlayer(title: "Harbour Lights", artist: "Stub Arrows",
                                             status: .playing(progress: 0.5, secondsLeft: 15), onStop: {}, onNext: {})
                let button = PreviewButton(status: .noPreview) {}
                for (name, view) in [("row", AnyView(row)), ("mini", AnyView(mini)), ("button", AnyView(button))] {
                    let host = UIHostingController(rootView: view.environment(\.dynamicTypeSize, size)
                        .environment(\.colorScheme, scheme))
                    let fit = host.sizeThatFits(in: CGSize(width: 375, height: CGFloat.infinity))
                    #expect(fit.width <= 375.5 && fit.height > 0, "\(name) at \(size) \(scheme): \(fit)")
                    if name == "button" { #expect(fit.width >= 44 && fit.height >= 44) }
                }
            }
        }
    }

    /// Fix I3 (D3, owner answer 7): "No preview available" and "Preview unavailable right now" are shown as words in place
    /// of the play button, not as a glyph alone. The words grow with Dynamic Type (to AX5) and wrap within the phone.
    @Test func noPreviewAndUnavailableShowTheirWords() {
        func fit(_ status: PreviewStatus, _ size: DynamicTypeSize, width: CGFloat = 375) -> CGSize {
            UIHostingController(rootView: PreviewButton(status: status) {}.environment(\.dynamicTypeSize, size))
                .sizeThatFits(in: CGSize(width: width, height: CGFloat.infinity))
        }
        for status in [PreviewStatus.noPreview, .unavailable] {
            #expect(status.showsWords)
            let large = fit(status, .large)
            #expect(large.width > 100, "\(status.label) is written out: \(large)")
            let ax5 = fit(status, .accessibility5)
            #expect(ax5.height > large.height, "the words grow with Dynamic Type")
            #expect(ax5.width <= 375.5)
            #expect(ax5.height >= 44)
        }
        for status in [PreviewStatus.ready, .loading, .playing(progress: 0.2, secondsLeft: 24)] {
            #expect(!status.showsWords)
            #expect(fit(status, .large).width < 60, "play, stop and loading stay a round button")
        }
        // In a row at AX5 the words still fit a 375-point phone beside nothing cut off.
        for status in [PreviewStatus.noPreview, .unavailable] {
            let row = PreviewRow(title: "Harbour Lights", artist: "Stub Arrows", status: status, onPreview: {}) {
                Button("Listen to the full song") {}
            }
            let host = UIHostingController(rootView: row.environment(\.dynamicTypeSize, .accessibility5))
            let size = host.sizeThatFits(in: CGSize(width: 375, height: CGFloat.infinity))
            #expect(size.width <= 375.5 && size.height > 0)
        }
    }

    // MARK: - Lock screen

    @MainActor final class Silent: PreviewEngine {
        let events = AsyncStream<PreviewEngineEvent> { $0.finish() }
        var loads: [Int] = []
        func load(_ clip: Data, token: Int, at: TimeInterval) { loads.append(token) }
        func pause() {}
        func resume() {}
        func stop() {}
    }

    @Test func theLockScreenShowsThePreviewWhileItPlays() async throws {
        let engine = Silent()
        let preview = PreviewPlayer(engine: engine, mainPlayer: nil)
        preview.lookup = { _ in .playable(Data("clip".utf8)) }
        #expect(NowPlayingBridge.previewInfo(preview) == nil, "nothing previewing: the main player's info")
        #expect(!NowPlayingBridge.previewTakes(.togglePlayPause, preview))

        preview.play([PreviewItem(id: "a", previewId: "1", title: "Harbour Lights", artist: "Stub Arrows", album: "Coast"),
                      PreviewItem(id: "b", previewId: "2", title: "Paper Moon", artist: "Stub Arrows")])
        for _ in 0..<100 where engine.loads.isEmpty { await Task.yield() }
        let token = try #require(engine.loads.last)
        preview.handle(.started(token: token))
        preview.handle(.time(token: token, 12, duration: 30))
        let info = try #require(NowPlayingBridge.previewInfo(preview))
        #expect(info[MPMediaItemPropertyTitle] as? String == "Harbour Lights")
        #expect(info[MPMediaItemPropertyArtist] as? String == "Stub Arrows")
        #expect(info[MPMediaItemPropertyAlbumTitle] as? String == "Coast")
        #expect(info[MPMediaItemPropertyPlaybackDuration] as? Double == 30)
        #expect(info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double == 12)
        #expect(info[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 1)
        #expect(info[MPNowPlayingInfoPropertyPlaybackQueueCount] as? Int == 2)

        #expect(NowPlayingBridge.previewTakes(.pause, preview))
        #expect(NowPlayingBridge.previewInfo(preview)?[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 0)
        preview.stop()
        #expect(NowPlayingBridge.previewInfo(preview) == nil, "stopped: the main player's info comes back")
        #expect(!NowPlayingBridge.previewTakes(.play, preview))
    }
}
