import AVFoundation
import AVKit
import DesignSystem
import SwiftUI
import UIKit

/// Round 21 (owner, 2026-11-06: "ensure Magpie can connect to bluetooth and all airplay features are available", D167):
/// the system's output picker in Now Playing's bottom row, in every look. A tap lists this iPhone, Bluetooth headphones
/// and speakers, AirPlay speakers and TVs (several at once for AirPlay 2); audio outputs come first. It shows in the
/// theme's ink, and in its accent while the sound plays elsewhere; the line under the scrubber says where (D3).
/// VoiceOver: "Play on…", with where it plays now as its value. CarPlay has its own Now Playing (no picker there).
struct OutputPicker: UIViewRepresentable {
    var tint: Color
    var activeTint: Color
    /// Where the sound plays now, for VoiceOver ("This iPhone", "Kitchen").
    var current: String

    func makeUIView(context: Context) -> OutputPickerView {
        let view = OutputPickerView()
        view.prioritizesVideoDevices = false
        view.isAccessibilityElement = true
        view.accessibilityLabel = "Play on\u{2026}"
        view.accessibilityTraits = .button
        view.accessibilityIdentifier = "np-output-picker"
        return view
    }

    func updateUIView(_ view: OutputPickerView, context: Context) {
        view.tintColor = UIColor(tint)
        view.activeTintColor = UIColor(activeTint)
        view.accessibilityValue = current
    }
}

/// The picker as one VoiceOver element under our own label (the system's names a service, which Magpie's copy doesn't).
/// Activating it presses the system's button inside.
final class OutputPickerView: AVRoutePickerView {
    override func accessibilityActivate() -> Bool {
        guard let button = Self.button(in: self) else { return false }
        button.sendActions(for: .touchUpInside)
        return true
    }

    private static func button(in view: UIView) -> UIButton? {
        for sub in view.subviews {
            if let button = sub as? UIButton { return button }
            if let button = button(in: sub) { return button }
        }
        return nil
    }
}

/// Keeps `output` current: read on appear and after every route change (AirPlay picked, Bluetooth on or off).
struct OutputRouteTracking: ViewModifier {
    @Binding var output: OutputRoute.Output?

    func body(content: Content) -> some View {
        content
            .onAppear { output = OutputRoute.current() }
            .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)
                .receive(on: RunLoop.main)) { _ in output = OutputRoute.current() }
    }
}
