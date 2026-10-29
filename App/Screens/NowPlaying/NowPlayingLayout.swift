import DesignSystem
import SwiftUI

/// Now Playing fits one screen at standard text sizes (D43): the art takes the height the rest leaves.
/// If even the smallest art doesn't fit, Up next goes first (Queue still reaches it), then the spacing tightens.
enum NowPlayingLayout {
    struct Plan: Equatable {
        var side: CGFloat
        var showsUpNext: Bool
        var spacing: CGFloat
    }

    /// The art's side: as wide as the content, as tall as `reserved` leaves, at most `maxSide`, never below `minSide`.
    static func artSide(available: CGSize, reserved: CGFloat, maxSide: CGFloat = 360, minSide: CGFloat = 120) -> CGFloat {
        max(minSide, min(available.width, available.height - reserved, maxSide))
    }

    /// Whether the art still gets `minSide` with `reserved` (which includes the Up next row and its gap) taken.
    static func showsUpNext(available: CGSize, reserved: CGFloat, minSide: CGFloat = 120) -> Bool {
        available.height - reserved >= minSide
    }

    /// `parts`: measured heights of everything stacked except the art and Up next, vertical padding included.
    /// `gaps`: the spaces between those parts and the art. `upNext`: the Up next row's height, nil without a next song.
    static func plan(available: CGSize, parts: CGFloat, gaps: Int, upNext: CGFloat?,
                     maxSide: CGFloat = 360, minSide: CGFloat = 120) -> Plan {
        let roomy = Tokens.Spacing.xl, tight = Tokens.Spacing.m
        func reserved(_ spacing: CGFloat, upNext shown: Bool) -> CGFloat {
            parts + CGFloat(gaps) * spacing + (shown ? (upNext ?? 0) + spacing : 0)
        }
        let shows = upNext != nil
            && showsUpNext(available: available, reserved: reserved(roomy, upNext: true), minSide: minSide)
        let spacing = shows || available.height - reserved(roomy, upNext: false) >= minSide ? roomy : tight
        let side = artSide(available: available, reserved: reserved(spacing, upNext: shows), maxSide: maxSide, minSide: minSide)
        return Plan(side: side, showsUpNext: shows, spacing: spacing)
    }
}

extension EnvironmentValues {
    /// Tests only: told each Now Playing part's frame in window coordinates as it lays out.
    @Entry var nowPlayingFrameProbe: (@MainActor (String, CGRect) -> Void)?
    /// Tests only: told each height Now Playing stores for its plan (a store lays the page out again).
    @Entry var nowPlayingHeightProbe: (@MainActor (String, CGFloat) -> Void)?
}

extension View {
    /// Reports this part's natural height into `heights` under `key`. A part that comes and goes (the hint, the
    /// error) keeps its last height; the caller counts it only while it shows.
    func nowPlayingPart(_ key: String, into heights: Binding<[String: CGFloat]>) -> some View {
        fixedSize(horizontal: false, vertical: true).modifier(NowPlayingPartReport(key: key, heights: heights))
    }

    /// Reports this view's height into `height`, the way `nowPlayingPart` does (Up next, which isn't summed).
    func nowPlayingHeight(_ key: String, into height: Binding<CGFloat>) -> some View {
        modifier(NowPlayingHeightReport(key: key, height: height))
    }

    /// Reports only the frame, to the test probe.
    func nowPlayingProbe(_ key: String) -> some View {
        modifier(NowPlayingPartReport(key: key, heights: nil))
    }
}

private struct NowPlayingPartReport: ViewModifier {
    let key: String
    let heights: Binding<[String: CGFloat]>?
    @Environment(\.nowPlayingFrameProbe) private var probe
    @Environment(\.nowPlayingHeightProbe) private var heightProbe
    @Environment(\.displayScale) private var scale

    func body(content: Content) -> some View {
        // The laid-out height, not the window frame's: under the Queue sheet the page is scaled down, and its scaled
        // heights came back a float apart on every pass (QC). The probe still gets the window frame.
        content.onGeometryChange(for: Measure.self) { Measure(height: $0.size.height, frame: $0.frame(in: .global)) } action: { m in
            if let heights, let h = MeasuredHeight.toStore(m.height, over: heights.wrappedValue[key], scale: scale) {
                heights.wrappedValue[key] = h
                heightProbe?(key, h)
            }
            probe?(key, m.frame)
        }
    }

    private struct Measure: Equatable {
        var height: CGFloat
        var frame: CGRect
    }
}

private struct NowPlayingHeightReport: ViewModifier {
    let key: String
    let height: Binding<CGFloat>
    @Environment(\.nowPlayingHeightProbe) private var heightProbe
    @Environment(\.displayScale) private var scale

    func body(content: Content) -> some View {
        content.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { new in
            guard let h = MeasuredHeight.toStore(new, over: height.wrappedValue, scale: scale) else { return }
            height.wrappedValue = h
            heightProbe?(key, h)
        }
    }
}
