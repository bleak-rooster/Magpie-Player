import MagpieCore
import SwiftUI

/// The options of a quality picker, grouped by codec in enum order: Original, AAC, Opus, MP3. Settings › Playback
/// (Wi-Fi, Mobile data) and the Downloads quality picker share it, so they always list the same choices.
struct StreamQualityOptions: View {
    static func heading(forFormat format: String) -> String {
        switch format {
        case "raw": "Original"
        case "aac": "AAC"
        case "opus": "Opus"
        default: "MP3"
        }
    }

    var body: some View {
        ForEach(StreamQuality.groups, id: \.format) { group in
            Section(Self.heading(forFormat: group.format)) {
                ForEach(group.qualities, id: \.self) { Text($0.title).tag($0) }
            }
        }
    }
}
