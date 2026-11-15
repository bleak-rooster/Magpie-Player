import DesignSystem
import Foundation
import MagpieCore
import SwiftUI

/// Round 28 O3 (owner, 2026-11-15, item 1: "when music is downloaded, you should be able to access the page with that
/// music … In offline mode, only downloaded songs are visible within albums, artists, songs, etc."): the words the
/// phone's pages use offline (plan §8, final), and where a page's songs came from (D340–D345).
enum OfflinePageCopy {
    /// Partial album, playlist or flow (D341): "<n> of <m> songs on this phone"; the count unknown: "<n> songs on this
    /// phone". Nil when every song is on the phone (nothing to say).
    static func onPhone(_ onPhone: Int, of total: Int?) -> String? {
        guard let total else { return onPhone == 1 ? "1 song on this phone" : "\(onPhone) songs on this phone" }
        guard onPhone < total else { return nil }
        return "\(onPhone) of \(total) songs on this phone"
    }

    static let onPhoneSymbol = "arrow.down.circle"
    /// The artist page offline: songs where they are only the track artist (D341).
    static let songsOnThisPhone = "Songs on this phone"
    /// An empty offline list (today's Home copy, D340).
    static let nothingDownloaded = "Nothing downloaded yet"
    static let nothingDownloadedDetail = "Albums and playlists you download play here without a connection."
    /// The queue offline (D342).
    static let notOnThisPhone = "Not on this phone"
    static let notOnThisPhoneValue = "Not on this phone, skipped while offline"
    static let notOnThisPhoneSymbol = "wifi.slash"
    /// A failed online read with the phone's copy shown (D341).
    static let phoneCopy = "Couldn\u{2019}t reach your library. Showing what\u{2019}s on this phone."
    static let phoneCopySymbol = "wifi.exclamationmark"
    /// A flow's Download (D343).
    static let downloadFlow = "Download"
    static let downloadFlowLabel = "Download this flow to your phone"
    static let downloadFlowSymbol = "arrow.down.circle"
}

/// Round 28 O3 (D341): where an album, artist, playlist or flow page's content came from.
enum PageSource: Equatable, Sendable {
    /// Read from the server just now.
    case server
    /// Offline (or a page the phone grouped itself): what's on the phone.
    case phone
    /// Online, but the read failed: the phone's copy, with `PhoneCopyNote` (D341).
    case phoneCopy

    var isPhone: Bool { self != .server }

    /// Round 28 O3 (D341): a failed online read shows the phone's copy, unless it was only cut short (D77: a cancelled
    /// load shows no error and changes nothing).
    static func fallsBack(after error: any Error) -> Bool { !AppModel.isCancellation(error) }
}

/// Round 28 O3 (D341): "<n> of <m> songs on this phone" under a partial page's header, as text plus its symbol (D3).
struct OnPhoneCountLine: View {
    let onPhone: Int
    let total: Int?
    private let themed = Themed()

    var body: some View {
        if let text = OfflinePageCopy.onPhone(onPhone, of: total) {
            Label(text, systemImage: OfflinePageCopy.onPhoneSymbol)
                .font(.footnote)
                .foregroundStyle(themed.palette.ink2Color)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("on-phone-count")
        }
    }
}

/// Round 28 O3 (owner, 2026-11-15; O1's design M4, D329): the offline notice as a screen's top inset (Home, Library,
/// Search, Downloads), above the scroll view rather than a row in it, so nothing under a finger moves when it comes or
/// goes. Nothing while online or only checking; never animated in or out.
struct OfflineNoticeInset: View {
    @Environment(AppModel.self) private var model
    private let themed = Themed()

    var body: some View {
        Group {
            if OfflineNotice.variant(for: model) != nil {
                OfflineNotice()
                    .padding(.horizontal, Tokens.Spacing.largeTitleMargin)
                    .padding(.vertical, Tokens.Spacing.s)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(themed.palette.bgColor)
            }
        }
        .transaction { $0.animation = nil }
    }
}

/// Round 28 O3 (D340): an offline list with nothing in it (today's Home copy).
struct NothingDownloadedView: View {
    var body: some View {
        ContentUnavailableView(OfflinePageCopy.nothingDownloaded, systemImage: "arrow.down.circle",
                               description: Text(OfflinePageCopy.nothingDownloadedDetail))
            .accessibilityIdentifier("offline-empty")
    }
}
