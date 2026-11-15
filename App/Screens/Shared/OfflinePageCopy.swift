import DesignSystem
import Foundation
import MagpieCore
import Playback
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
    /// The artist page offline: songs where they are only the track artist (D341; fix round 1, design M8).
    static let songsOnThisPhone = "Also on this phone"
    /// An empty offline list when nothing at all is downloaded (today's Home copy, D340).
    static let nothingDownloaded = "Nothing downloaded yet"
    static let nothingDownloadedDetail = "Albums and playlists you download play here without a connection."
    /// The queue offline (D342).
    static let notOnThisPhone = "Not on this phone"
    static let notOnThisPhoneValue = "Not on this phone, skipped while offline"
    static let notOnThisPhoneSymbol = "wifi.slash"
    /// A failed online read with the phone's copy shown (D341), and its way to read again (fix round 1, design M4).
    static let phoneCopy = "Couldn\u{2019}t reach your library. Showing what\u{2019}s on this phone."
    static let phoneCopySymbol = "wifi.exclamationmark"
    static let tryAgain = "Try again"
    /// A flow's Download (D343; fix round 1, design M2, M3: today's capsule, with a line under it).
    static let downloadFlowLabel = "Download"
    static let downloadFlowHint = "Downloads this flow to this phone"
    static func flowAbout(_ count: Int) -> String { count == 1 ? "About 1 song" : "About \(count) songs" }
    static let flowFollows = "New songs download when this flow changes"

    /// Fix round 1 (design H1): one answer per page. The download mark shows unless the count line already says how
    /// much of it is here (the phone's page, partial or of unknown size).
    static func showsMark(_ source: PageSource, onPhone: Int, total: Int?) -> Bool {
        !source.isPhone || Self.onPhone(onPhone, of: total) == nil
    }

    /// Fix round 1 (design M10): a row's Add to playlist and Favourite need the server: only on the server's page,
    /// online. The phone's copy of a failed read is treated as offline.
    static func serverRowMenus(_ source: PageSource, offline: Bool) -> Bool { source == .server && !offline }
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

    /// Round 28 O3 (D341; fix round 1, review I1): only a read that got no answer from the library shows the phone's
    /// copy: a connection error, a gateway or portal page, a refused redirect (D325's server-path failures), or Offline
    /// mode. The library's own answer — a Subsonic error (70: gone), a refused sign-in, any other status — keeps today's
    /// error; a load cut short shows nothing new (D77).
    static func fallsBack(after error: any Error) -> Bool {
        AppModel.isConnectionError(error) || AppModel.isServerPathFailure(error)
    }

    /// Fix round 1 (review I2): and only over nothing, or over what already came from the phone; a server page on screen
    /// stays with Z2's quiet "not refreshed".
    static func fallsBack(after error: any Error, onScreen: PageSource?) -> Bool {
        fallsBack(after: error) && (onScreen?.isPhone ?? true)
    }
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

/// Fix round 1 (design M10): a song row's menu on the phone's pages: Play next and Add to queue, and Remove download
/// for a download (it asks first); nothing that needs the server.
struct PhoneSongMenuItems: View {
    @Environment(AppModel.self) private var model
    let song: Song
    @Binding var removing: Song?

    var body: some View {
        SongQueueMenuItems(song: song)
        if model.downloadStatus([song.id]) == .downloaded {
            Section {
                Button(SongDownloadMenuItem.removeTitle, systemImage: "trash", role: .destructive) { removing = song }
            }
        }
    }
}

/// Round 28 O3 (owner, 2026-11-15; O1's design M4, D329): the offline notice as a screen's top inset (Home, Library,
/// Search, Downloads), above the scroll view, never a row in the list, so nothing under a finger moves when it comes or
/// goes. Nothing while online or only checking; never animated in or out. Fix round 1 (design H5): at accessibility
/// sizes a pinned notice would take much of the screen, so there it is the scroll content's first row instead
/// (`OfflineNoticeRow`), and scrolls away.
struct OfflineNoticeInset: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize
    private let themed = Themed()

    /// Pinned above the scroll view below accessibility sizes.
    static func pinned(accessibility: Bool) -> Bool { !accessibility }

    var body: some View {
        Group {
            if Self.pinned(accessibility: typeSize.isAccessibilitySize), OfflineNotice.variant(for: model) != nil {
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

/// Fix round 1 (design H5): the notice as the first row of the scroll content, at accessibility sizes only (below
/// them `OfflineNoticeInset` pins it).
struct OfflineNoticeRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Group {
            if !OfflineNoticeInset.pinned(accessibility: typeSize.isAccessibilitySize), OfflineNotice.variant(for: model) != nil {
                OfflineNotice()
                    .padding(.horizontal, Tokens.Spacing.largeTitleMargin)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .transaction { $0.animation = nil }
    }
}

/// Fix round 1 (design M5): pull to refresh while offline. Offline by itself it tries the library again (D326); in
/// Offline mode nothing may be sent, so it reads the phone again and says "Offline mode is on".
enum OfflineRefresh {
    enum Action: Equatable { case online, reconnect, rereadAndAnnounce }

    static func action(_ state: OfflineState) -> Action {
        switch state {
        case .online, .suspect: .online
        case .automatic: .reconnect
        case .manual: .rereadAndAnnounce
        }
    }

    /// Runs the offline pull; false when online (the screen does its own refresh).
    @MainActor static func run(_ model: AppModel, reread: () async -> Void) async -> Bool {
        switch action(model.offlineState) {
        case .online:
            return false
        case .reconnect:
            await model.reconnectNow()
        case .rereadAndAnnounce:
            await reread()
            model.say(OfflineNoticeCopy.manual)
        }
        return true
    }
}

/// Round 28 O3 (D340): an offline list with nothing in it. Fix round 1 (design H3): "Nothing downloaded yet" only when
/// nothing is on the phone; otherwise the list says what it lacks (`OfflineLists.empty`).
struct NothingDownloadedView: View {
    var title = OfflinePageCopy.nothingDownloaded
    var detail: String? = OfflinePageCopy.nothingDownloadedDetail

    var body: some View {
        ContentUnavailableView(title, systemImage: "arrow.down.circle", description: detail.map { Text($0) })
            .accessibilityIdentifier("offline-empty")
    }
}
