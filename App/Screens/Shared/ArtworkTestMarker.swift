import Foundation
import MagpieCore
import UIKit
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

    /// Round 15 C4 (D140), UI tests only (`-MagpieUITesting YES -MagpieUITestArtistPicture <MBID>`): puts a plain
    /// picture for that artist in the phone's outside-art folder, as if the artist page's picture had loaded before (the
    /// localhost test stack has no public picture host). Home's recommended circle must then show it. A production launch
    /// never passes these arguments, so this does nothing there.
    static func seedArtistPicture(into disk: OutsideArtDiskCache, defaults: UserDefaults = .standard) {
        guard defaults.string(forKey: "MagpieUITesting") == "YES",
              let mbid = defaults.string(forKey: "MagpieUITestArtistPicture").flatMap(MBID.init) else { return }
        let png = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).pngData { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        disk.save(png, for: .artist(mbid))
    }
}
