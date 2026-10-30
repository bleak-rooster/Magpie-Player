import MagpieCore
import SwiftUI

/// The options of a quality picker, grouped by codec in enum order: Original, AAC, Opus, MP3, each codec's presets
/// reading "High · 320 kbps" (R5). Settings › Playback (Wi-Fi, Mobile data) and Downloads & Storage use it, so they
/// list the same choices.
struct StreamQualityOptions: View {
    /// What Original reads as (Settings › Downloads & Storage says it's the file as it is).
    var originalTitle = StreamQuality.original.title

    static func heading(forFormat format: String) -> String { StreamQuality.formatName(format) }

    var body: some View {
        ForEach(StreamQuality.groups, id: \.format) { group in
            Section(Self.heading(forFormat: group.format)) {
                ForEach(group.qualities, id: \.self) { Text($0 == .original ? originalTitle : $0.title).tag($0) }
            }
        }
    }
}

/// A quality picker whose collapsed value names the codec too ("AAC 160 kbps"): a row alone ("Medium · 160 kbps")
/// doesn't say which.
struct StreamQualityPicker: View {
    let title: String
    @Binding var selection: StreamQuality
    var originalTitle = StreamQuality.original.title

    var body: some View {
        Picker(title, selection: $selection) {
            StreamQualityOptions(originalTitle: originalTitle)
        } currentValueLabel: {
            Text(selection == .original ? originalTitle : selection.shortTitle)
        }
    }
}
