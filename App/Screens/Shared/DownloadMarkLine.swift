import DesignSystem
import SwiftUI

/// A page header's Downloaded mark (P1), symbol and text: "Downloaded" or "3 of 12 downloaded". Nothing for none.
struct DownloadMarkLine: View {
    let mark: DownloadMark
    private let themed = Themed()

    init(_ mark: DownloadMark) { self.mark = mark }

    var body: some View {
        if let text = mark.text, let symbol = mark.symbol {
            Label(text, systemImage: symbol)
                .font(.footnote)
                .foregroundStyle(themed.palette.ink2Color)
                .accessibilityIdentifier("download-mark-line")
        }
    }
}
