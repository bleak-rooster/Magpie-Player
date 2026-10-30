import SwiftUI

/// Whether a song, album, playlist or artist is on the phone as a download (P1, D3: a symbol plus a VoiceOver label).
/// Cached songs never count: only downloads do.
public enum DownloadMark: Hashable, Sendable {
    case none
    case downloaded
    /// Some of the songs: "3 of 12 downloaded".
    case partial(done: Int, total: Int)
    /// Some of an artist's songs, where the full count isn't known (the artist list).
    case some

    /// What VoiceOver says; nil for `.none`.
    public var text: String? {
        switch self {
        case .none: nil
        case .downloaded: "Downloaded"
        case let .partial(done, total): "\(done) of \(total) downloaded"
        case .some: "Some downloaded"
        }
    }

    public var symbol: String? {
        switch self {
        case .none: nil
        case .downloaded: "arrow.down.circle.fill"
        case .partial, .some: "arrow.down.circle.dotted"
        }
    }

    /// `done` of `total` songs downloaded: none, partial or all (an empty total is none).
    public static func counting(done: Int, total: Int) -> DownloadMark {
        guard total > 0, done > 0 else { return .none }
        return done >= total ? .downloaded : .partial(done: done, total: total)
    }
}

/// The small mark itself; nothing for `.none`. Its label is the mark's text, so a combined row reads it.
public struct DownloadMarkView: View {
    private let mark: DownloadMark
    private let themed = ThemedPalette()

    public init(_ mark: DownloadMark) { self.mark = mark }

    public var body: some View {
        if let symbol = mark.symbol {
            Image(systemName: symbol)
                .font(.caption)
                .foregroundStyle(themed.palette.ink2Color)
                .accessibilityLabel(mark.text ?? "")
                .accessibilityIdentifier("download-mark")
        }
    }
}

extension EnvironmentValues {
    /// Whether a song (by id) is on the phone as a download. The app sets it once at the root; song rows read it, so
    /// every row gets the mark without each screen passing it, and it updates live as downloads land or leave.
    @Entry public var songIsDownloaded: @MainActor @Sendable (String) -> Bool = { _ in false }
}

extension DownloadMark {
    /// A VoiceOver value with the mark's text added (`value` first), e.g. "Find, 5 days left, Downloaded".
    public func joined(to value: String?) -> String {
        [value, text].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }
}
