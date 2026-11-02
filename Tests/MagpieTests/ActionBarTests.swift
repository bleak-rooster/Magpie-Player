import DesignSystem
import MagpieCore
import SwiftUI
import Testing
import UIKit
@testable import Magpie

/// Each ActionBar item's global frame by its position in the bar (`actionBarProbe`); shared by the page tests.
@MainActor final class ActionBarFrames {
    var byIndex: [Int: CGRect] = [:]
    /// Every item frame reported, from every bar on the page (latest per position).
    var all: [String: CGRect] = [:]
    func record(_ index: Int, _ frame: CGRect) {
        byIndex[index] = frame
        all["\(index)@\(Int(frame.minY.rounded()))"] = frame
    }
}

/// Y7 (plan item 10): one ActionBar for every Play / Shuffle / Download row. Phase 2 (owner ruling): Play, Shuffle
/// and Download are three equal slots in one row, one height (at least 44 pt); Play is filled and the rest tinted;
/// Download keeps the same capsule in every state with a short label (VoiceOver reads the full status); the bar
/// stacks at accessibility sizes. Hosted in a real window so the layout settles.
@MainActor @Suite(.serialized) struct ActionBarTests {
    typealias Frames = ActionBarFrames

    // MARK: Arrangement (pure)

    @Test func twoItemsShareOneRowEqually() {
        let frames = ActionBarArrangement.frames(idealWidths: [80, 90], height: 44, width: 343, stacked: false)
        #expect(frames.count == 2)
        #expect(frames[0].width == frames[1].width)
        #expect(frames[0].minY == frames[1].minY)
        #expect(frames[0].minX == 0 && abs(frames[1].maxX - 343) < 0.01)
        #expect(frames.allSatisfy { $0.height == 44 })
    }

    /// Owner ruling (phase 2): Play, Shuffle and Download are the same size, side by side.
    @Test func threeItemsShareOneRowEqually() {
        let frames = ActionBarArrangement.frames(idealWidths: [80, 90, 100], height: 44, width: 343, stacked: false)
        #expect(Set(frames.map(\.minY)).count == 1, "\(frames)")
        #expect(Set(frames.map { ($0.width * 100).rounded() }).count == 1, "\(frames)")
        #expect(frames[0].minX == 0 && abs(frames[2].maxX - 343) < 0.01)
        #expect(frames.allSatisfy { $0.height == 44 })
    }

    /// A label up to 15 % wider than its slot still shares the row (its text may shrink a little, never truncate).
    @Test func aSlightlyWideLabelStillSharesTheRow() {
        let frames = ActionBarArrangement.frames(idealWidths: [100, 100, 125], height: 44, width: 343, stacked: false)
        #expect(Set(frames.map(\.minY)).count == 1, "\(frames)")
    }

    /// The Download capsule's short labels; VoiceOver keeps the full status.
    @Test func downloadShortLabels() {
        #expect(DownloadControl.shortTitle(.none) == "Download")
        #expect(DownloadControl.shortTitle(.downloading(done: 4, total: 10)) == "40%")
        #expect(DownloadControl.shortTitle(.downloaded) == "Downloaded")
        #expect(DownloadControl.shortTitle(.partial(done: 3, total: 12)) == "3 of 12")
        for status: DownloadStatus in [.waitingForWiFi, .waitingForConnection, .full, .failed] {
            #expect(DownloadControl.shortTitle(status).count <= 10, "\(status)")
        }
    }

    /// Review minor 8: whatever accent Immersive is handed (an art palette's, say), Shuffle's deep shade keeps its
    /// white label at AA; it never quietly keeps a fill that misses.
    @Test func immersiveSecondaryNeverMissesAA() {
        let ink = PaletteColor(hex: 0xFFFFFF)
        for hex: UInt32 in [0xFFFFFF, 0xFFFFE0, 0xF0F0F0, 0x3CC4B8, 0xF25C05, 0x3D5AFE, 0x000000, 0x7FFF00] {
            let fill = ActionStyle.immersiveSecondaryFill(accent: PaletteColor(hex: hex), label: ink)
            #expect(fill.alpha == 1)
            let shaded = PaletteColor(hex: 0x000000, alpha: 0.25).composited(over: fill)
            #expect(Contrast.ratio(ink, on: fill) >= 4.5 && Contrast.ratio(ink, on: shaded) >= 4.5, "\(String(hex, radix: 16))")
        }
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
        // Immersive capsules are always solid: a tint over art can drop to 1.9:1 (a11y C1). Y7 audit: Shuffle was the
        // same fill as Play there, so secondary is a deeper, opaque shade of the accent.
        let immersive = Theme(character: .immersive)
        let primary = ActionStyle.colors(.primary, theme: immersive, scheme: .dark)
        let secondary = ActionStyle.colors(.secondary, theme: immersive, scheme: .dark)
        #expect(secondary.fill.alpha == 1)
        #expect(secondary.fill != primary.fill)
        #expect(secondary.fill.relativeLuminance < primary.fill.relativeLuminance)
    }

    /// Y7 audit: at accessibility sizes album tiles widen to 220 pt, so a phone-width grid shows one column (two
    /// overlapped and ran off the screen).
    @Test func albumGridIsOneColumnAtAccessibilitySizes() {
        #expect(AlbumGrid.columnCount(width: 362, accessibility: false) == 2)
        #expect(AlbumGrid.columnCount(width: 362, accessibility: true) == 1)
        #expect(AlbumGrid.columnCount(width: 700, accessibility: true) == 3)
        #expect(AlbumGrid.columnCount(width: 700, accessibility: false) == 4)
    }

    // MARK: Hosted

    /// Play, Shuffle and Download: three equal slots in one row, one height of at least 44 pt, inside the 16 pt
    /// margins, in every Character, on the smallest phone (375 pt).
    @Test func barItemsShareWidthsAndHeight() async throws {
        for character in DesignSystem.Character.allCases {
            for status: DownloadStatus in [.downloading(done: 4, total: 10), .downloaded, .waitingForConnection] {
                let frames = try await Self.host(Self.bar(status), theme: Theme(character: character))
                Self.expectBar(frames, count: 3, width: 375, label: "\(character) \(status)")
            }
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

    /// Every item on one row with one width and one height ≥ 44, side by side, inside the 16 pt margins.
    static func expectBar(_ frames: Frames, count: Int, width: CGFloat, label: String) {
        let all = (0..<count).compactMap { frames.byIndex[$0] }
        guard all.count == count else { Issue.record("\(label): only \(frames.byIndex.keys.sorted()) laid out"); return }
        #expect(Set(all.map { ($0.height * 2).rounded() }).count == 1, "\(label): heights \(all.map(\.height))")
        #expect(Set(all.map { ($0.width * 2).rounded() }).count == 1, "\(label): widths \(all.map(\.width))")
        #expect(Set(all.map { ($0.minY * 2).rounded() }).count == 1, "\(label): not one row \(all)")
        #expect(all.allSatisfy { $0.height >= 44 }, "\(label): \(all)")
        #expect(abs(all[0].minX - 16) < 0.5 && abs(all[count - 1].maxX - (width - 16)) < 0.5, "\(label): \(all)")
        for (a, b) in zip(all, all.dropFirst()) { #expect(b.minX >= a.maxX, "\(label): overlap \(all)") }
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
