import DesignSystem
import MagpieCore
import SwiftUI
import Testing
import UIKit
@testable import Magpie

/// Y7 (plan item 10): one ActionBar for every Play / Shuffle / Download row. Its items share one width per row and
/// one height (at least 44 pt), Play is filled and the rest tinted, Download keeps the same capsule in every state,
/// and the bar stacks at accessibility sizes. Hosted in a real window so the layout settles; the bar reports each
/// item's frame through `actionBarProbe`.
@MainActor @Suite(.serialized) struct ActionBarTests {
    @MainActor final class Frames { var byIndex: [Int: CGRect] = [:] }

    // MARK: Arrangement (pure)

    @Test func twoItemsShareOneRowEqually() {
        let frames = ActionBarArrangement.frames(idealWidths: [80, 90], height: 44, width: 343, stacked: false)
        #expect(frames.count == 2)
        #expect(frames[0].width == frames[1].width)
        #expect(frames[0].minY == frames[1].minY)
        #expect(frames[0].minX == 0 && abs(frames[1].maxX - 343) < 0.01)
        #expect(frames.allSatisfy { $0.height == 44 })
    }

    @Test func threeItemsPutTheThirdOnItsOwnRow() {
        let frames = ActionBarArrangement.frames(idealWidths: [80, 90, 110], height: 44, width: 343, stacked: false)
        #expect(frames[0].width == frames[1].width && frames[0].minY == frames[1].minY)
        #expect(frames[2].minY > frames[0].maxY && frames[2].width == 343)
        #expect(frames.allSatisfy { $0.height == 44 })
    }

    @Test func aLabelThatWouldTruncateStacksTheBar() {
        let frames = ActionBarArrangement.frames(idealWidths: [80, 200], height: 44, width: 343, stacked: false)
        #expect(frames.allSatisfy { $0.width == 343 })
        #expect(frames[1].minY > frames[0].maxY)
    }

    @Test func accessibilitySizesStack() {
        let frames = ActionBarArrangement.frames(idealWidths: [60, 60], height: 60, width: 343, stacked: true)
        #expect(frames.allSatisfy { $0.width == 343 && $0.height == 60 })
        #expect(frames[1].minY > frames[0].maxY)
    }

    // MARK: Contrast

    /// Every label in the bar meets AA (4.5:1) on what it sits on: the primary fill, the tint, and a Download
    /// capsule's progress fill, in every Character, accent and scheme.
    @Test func everyCapsuleMeetsContrast() {
        var failures: [String] = []
        for character in DesignSystem.Character.allCases {
            for accent in AccentChoice.allCases {
                for scheme in [ColorScheme.light, .dark] {
                    let theme = Theme(character: character, accent: accent)
                    let bg = theme.colors(for: scheme).bg
                    for prominence in [ActionProminence.primary, .secondary] {
                        let c = ActionStyle.colors(prominence, theme: theme, scheme: scheme)
                        let base = c.fill.composited(over: bg)
                        let done = c.progress.composited(over: base)
                        for (name, surface) in [("fill", base), ("progress", done)] {
                            let ratio = Contrast.ratio(c.label, on: surface)
                            if ratio < 4.5 { failures.append("\(character) \(accent) \(scheme) \(prominence) \(name) = \(ratio)") }
                        }
                    }
                }
            }
        }
        #expect(failures.isEmpty, "\(failures)")
    }

    @Test func primaryIsFilledAndSecondaryTinted() {
        for character in [DesignSystem.Character.classic, .signature] {
            let theme = Theme(character: character)
            let p = theme.colors(for: .light)
            #expect(ActionStyle.colors(.primary, theme: theme, scheme: .light).fill == p.accent)
            #expect(ActionStyle.colors(.secondary, theme: theme, scheme: .light).fill.alpha < 0.5)
        }
        // Immersive capsules are always solid: a tint over art can drop to 1.9:1 (a11y C1).
        let immersive = Theme(character: .immersive)
        #expect(ActionStyle.colors(.secondary, theme: immersive, scheme: .dark).fill.alpha == 1)
    }

    // MARK: Hosted

    /// Play, Shuffle and Download: the first two share a row with one width, Download fills the next row, and all
    /// three are one height of at least 44 pt, inside the 16 pt margins, in every Character.
    @Test func barItemsShareWidthsAndHeight() async throws {
        for character in DesignSystem.Character.allCases {
            let frames = try await Self.host(Self.bar(.downloading(done: 4, total: 10)), theme: Theme(character: character))
            Self.expectBar(frames, count: 3, width: 375, label: "\(character)")
        }
    }

    /// The Download capsule is the same size in every state, and the bar around it doesn't move.
    @Test func downloadCapsuleKeepsItsSizeInEveryState() async throws {
        let states: [DownloadStatus] = [.none, .downloading(done: 4, total: 10), .downloaded, .waitingForWiFi,
                                        .waitingForConnection, .full, .failed, .partial(done: 3, total: 12)]
        var sizes: [String: [CGRect]] = [:]
        for status in states {
            let frames = try await Self.host(Self.bar(status), theme: Theme())
            Self.expectBar(frames, count: 3, width: 375, label: "\(status)")
            sizes["\(status)"] = (0..<3).compactMap { frames.byIndex[$0] }
        }
        let first = try #require(sizes["\(DownloadStatus.none)"])
        for (status, frames) in sizes { #expect(frames == first, "\(status): \(frames) vs \(first)") }
    }

    /// At accessibility sizes every item takes the full width, one under the other, one height each.
    @Test func barStacksAtAccessibilitySizes() async throws {
        let frames = try await Self.host(Self.bar(.downloaded), theme: Theme(), typeSize: .accessibility3)
        let all = (0..<3).compactMap { frames.byIndex[$0] }
        #expect(all.count == 3)
        #expect(all.allSatisfy { abs($0.minX - 16) < 0.5 && abs($0.maxX - 359) < 0.5 }, "\(all)")
        #expect(Set(all.map { $0.height.rounded() }).count == 1 && all[0].height >= 44, "\(all)")
        #expect(all[1].minY > all[0].maxY && all[2].minY > all[1].maxY)
    }

    /// A genre group's one Shuffle fills the row at the same height.
    @Test func singleItemFillsTheRow() async throws {
        let frames = try await Self.host(AnyView(ActionBar {
            ActionButton("Shuffle", symbol: "shuffle") {}
        }), theme: Theme())
        let only = try #require(frames.byIndex[0])
        #expect(abs(only.minX - 16) < 0.5 && abs(only.maxX - 359) < 0.5 && only.height >= 44, "\(only)")
    }

    // MARK: Helpers

    static func bar(_ status: DownloadStatus) -> AnyView {
        AnyView(ActionBar {
            ActionButton("Play", symbol: "play.fill", prominence: .primary) {}
            ActionButton("Shuffle", symbol: "shuffle") {}
            DownloadControl(status: status, canStart: true, start: {}, retry: {}, remove: {})
        })
    }

    /// Items 0–1 on one row with one width; item 2 (if any) the full width below; one height ≥ 44; 16 pt margins.
    static func expectBar(_ frames: Frames, count: Int, width: CGFloat, label: String) {
        let all = (0..<count).compactMap { frames.byIndex[$0] }
        guard all.count == count else { Issue.record("\(label): only \(frames.byIndex.keys.sorted()) laid out"); return }
        let heights = Set(all.map { ($0.height * 2).rounded() })
        #expect(heights.count == 1, "\(label): heights \(all.map(\.height))")
        #expect(all.allSatisfy { $0.height >= 44 }, "\(label): \(all)")
        #expect(abs(all[0].width - all[1].width) < 0.5 && abs(all[0].minY - all[1].minY) < 0.5, "\(label): \(all)")
        #expect(abs(all[0].minX - 16) < 0.5 && abs(all[1].maxX - (width - 16)) < 0.5, "\(label): \(all)")
        #expect(all[1].minX >= all[0].maxX, "\(label): overlap \(all)")
        if count == 3 {
            #expect(abs(all[2].minX - 16) < 0.5 && abs(all[2].maxX - (width - 16)) < 0.5, "\(label): \(all)")
            #expect(all[2].minY >= all[0].maxY, "\(label): \(all)")
        }
    }

    static func host(_ view: AnyView, theme: Theme, typeSize: DynamicTypeSize = .large,
                     width: CGFloat = 375) async throws -> Frames {
        let frames = Frames()
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: width, height: 667)
        let root = VStack { view; Spacer() }
            .magpieTheme(theme)
            .environment(\.dynamicTypeSize, typeSize)
            .environment(\.actionBarProbe) { index, frame in frames.byIndex[index] = frame }
        let host = UIHostingController(rootView: root)
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        for _ in 0..<5 {
            try await Task.sleep(for: .milliseconds(60))
            host.view.layoutIfNeeded()
        }
        return frames
    }
}
