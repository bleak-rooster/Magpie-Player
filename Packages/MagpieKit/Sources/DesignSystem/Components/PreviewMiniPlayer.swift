import SwiftUI

/// Round 14 A2 (D86): the mini player while a preview plays. The song and "Preview", the 30-second ring around Stop, and
/// Next when a list is previewing. Same bar as `MiniPlayer` (text stops growing at xxxLarge; Large Content Viewer).
public struct PreviewMiniPlayer: View {
    private let title: String
    private let artist: String
    private let artwork: Image?
    private let status: PreviewStatus
    private let onStop: () -> Void
    private let onNext: (() -> Void)?
    private let themed = ThemedPalette()
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    public init(title: String, artist: String, artwork: Image? = nil, status: PreviewStatus,
                onStop: @escaping () -> Void, onNext: (() -> Void)? = nil) {
        self.title = title; self.artist = artist; self.artwork = artwork; self.status = status
        self.onStop = onStop; self.onNext = onNext
    }

    public var body: some View {
        let ax = typeSize.isAccessibilitySize
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                SleeveArt(image: artwork, side: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text("Preview · \(artist)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityShowsLargeContentViewer { Text("Preview: \(title), \(artist)") }
            .accessibilityLabel("Preview: \(title), \(artist)")
            .accessibilityValue(status.accessibilityValue)

            PreviewButton(status: status, action: onStop)
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .accessibilityLabel("Stop preview")

            if let onNext, !ax {
                Button(action: onNext) {
                    Image(systemName: "forward.fill")
                        .font(.title3).frame(width: Tokens.minHitSize, height: Tokens.minHitSize).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Next preview")
            }
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 8).padding(.vertical, ax ? 2 : 6)
        .frame(minHeight: ax ? 0 : 52)
        .background { background }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Stop preview", onStop)
        .modifier(OptionalAction(name: "Next preview", action: onNext))
        .accessibilityIdentifier("preview-mini-player")
    }

    @ViewBuilder private var background: some View {
        let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)
        if reduceTransparency {
            shape.fill(themed.palette.surfaceColor).overlay(shape.strokeBorder(themed.palette.sepColor))
        } else {
            shape.fill(.regularMaterial)
        }
    }
}

private struct OptionalAction: ViewModifier {
    let name: String
    let action: (() -> Void)?
    func body(content: Content) -> some View {
        if let action { content.accessibilityAction(named: name, action) } else { content }
    }
}

#Preview("PreviewMiniPlayer") {
    VStack {
        PreviewMiniPlayer(title: "Harbour Lights", artist: "Stub Arrows", status: .playing(progress: 0.5, secondsLeft: 15),
                          onStop: {}, onNext: {})
        PreviewMiniPlayer(title: "Harbour Lights", artist: "Stub Arrows", status: .loading, onStop: {})
    }
    .padding()
}
