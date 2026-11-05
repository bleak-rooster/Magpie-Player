import Foundation
import SwiftUI

/// Round 15 C1: the UI tests' hook for "is the real picture showing?" (Top songs rows, the preview mini player).
extension View {
    /// UI tests only (`-MagpieUITesting YES`): a 1-point element labelled `name` (a label, since a container's
    /// identifier replaces its children's), whose value says whether the real picture shows ("artwork-loaded") or the
    /// placeholder. Nothing at all otherwise (VoiceOver never meets it).
    @ViewBuilder func artworkTestMarker(_ name: String, loaded: Bool) -> some View {
        if ArtworkTestMarker.enabled {
            overlay(alignment: .topLeading) {
                Color.clear.frame(width: 1, height: 1)
                    .accessibilityElement()
                    .accessibilityLabel(name)
                    .accessibilityIdentifier(name)
                    .accessibilityValue(loaded ? "artwork-loaded" : "placeholder")
            }
        } else {
            self
        }
    }
}

enum ArtworkTestMarker {
    static let enabled = UserDefaults.standard.string(forKey: "MagpieUITesting") == "YES"
}
