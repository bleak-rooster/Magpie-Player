import MagpieCore
import SwiftUI

/// The options of a quality picker, grouped by codec in enum order: Original, AAC, Opus, MP3. Settings › Playback
/// (Wi-Fi, Mobile data) uses it, and any other quality picker should, so they list the same choices.
struct StreamQualityOptions: View {
    /// What Original reads as (Settings › Downloads & Storage says it's the file as it is).
    var originalTitle = StreamQuality.original.title

    static func heading(forFormat format: String) -> String {
        switch format {
        case "raw": "Original"
        case "aac": "AAC"
        case "opus": "Opus"
        case "mp3": "MP3"
        default: format.uppercased()
        }
    }

    var body: some View {
        ForEach(StreamQuality.groups, id: \.format) { group in
            Section(Self.heading(forFormat: group.format)) {
                ForEach(group.qualities, id: \.self) { Text($0 == .original ? originalTitle : $0.title).tag($0) }
            }
        }
    }
}
