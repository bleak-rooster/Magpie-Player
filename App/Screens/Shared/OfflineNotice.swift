import DesignSystem
import SwiftUI

/// The offline notice, as text with its symbol (D3), on the screens offline mode changes (Task 14).
/// Round 28 O1 (owner, 2026-11-15, D329): it says who chose it. Offline mode on: "Offline mode is on" and Go online;
/// offline by itself: "Your library is out of reach…" and Try again ("Trying…" while a check runs). Nothing while
/// Magpie is only checking (suspect). It never animates; VoiceOver hears each switch once, from `AppModel`, not from
/// each notice on screen. `AppModel.offlineCopy` ("You're offline") stays the refusal everywhere else (D139).
///
/// Fix round 1: with no network path at all it says "No connection…" (design M2); Go online turns into "Trying…" in
/// place until the library answers (design H1); a failed Try again adds "Still out of reach" (design M1). It is one
/// self-contained block, so a screen can also put it in a top inset (design M4, O3's screens).
struct OfflineNotice: View {
    @Environment(AppModel.self) private var model
    private let themed = Themed()

    /// What the notice shows in each state: nil while online or only checking.
    struct Variant: Equatable {
        enum Action: Equatable { case goOnline, tryAgain, trying }
        var text: String
        var symbol: String
        var action: Action
        var actionTitle: String
        var actionIdentifier: String
        /// A line under the text (design M1: "Still out of reach").
        var detail: String? = nil
    }

    static func variant(_ state: OfflineState, checking: Bool, noConnection: Bool = false, leavingManual: Bool = false,
                        stillOutOfReach: Bool = false) -> Variant? {
        switch state {
        case .manual:
            return Variant(text: OfflineNoticeCopy.manual, symbol: "wifi.slash", action: .goOnline,
                           actionTitle: OfflineNoticeCopy.goOnline, actionIdentifier: "offline-go-online")
        case .automatic where leavingManual:
            // Design H1: Go online's check, in place of the button, under the words it had.
            return Variant(text: OfflineNoticeCopy.manual, symbol: "wifi.slash", action: .trying,
                           actionTitle: OfflineNoticeCopy.trying, actionIdentifier: "offline-go-online")
        case .automatic:
            return Variant(text: noConnection ? OfflineNoticeCopy.noConnection : OfflineNoticeCopy.automatic,
                           symbol: noConnection ? "wifi.slash" : "wifi.exclamationmark",
                           action: checking ? .trying : .tryAgain,
                           actionTitle: checking ? OfflineNoticeCopy.trying : OfflineNoticeCopy.tryAgain,
                           actionIdentifier: "offline-try-again",
                           detail: stillOutOfReach && !checking ? OfflineNoticeCopy.stillOutOfReach : nil)
        case .online, .suspect:
            return nil
        }
    }

    /// The variant for the model's state now.
    @MainActor static func variant(for model: AppModel) -> Variant? {
        let r = model.reachability
        return variant(model.offlineState, checking: r.checking, noConnection: model.offlineNoConnection,
                       leavingManual: r.leavingManual, stillOutOfReach: r.stillOutOfReach)
    }

    var body: some View {
        content
            .transaction { $0.animation = nil }
    }

    @ViewBuilder private var content: some View {
        if let variant = Self.variant(for: model) {
            VStack(alignment: .leading, spacing: 4) {
                Label(variant.text, systemImage: variant.symbol)
                    .font(.subheadline)
                    .foregroundStyle(themed.palette.ink2Color)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("offline-notice")
                if let detail = variant.detail {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(themed.palette.ink2Color)
                        .accessibilityIdentifier("offline-still-out-of-reach")
                }
                Button {
                    switch variant.action {
                    case .goOnline: model.goOnline()
                    case .tryAgain: Task { await model.tryAgain() }
                    case .trying: break
                    }
                } label: {
                    // Task review M3: the 44 pt target is the label's own frame and shape, so all of it acts.
                    HStack(spacing: 6) {
                        if variant.action == .trying { ProgressView().accessibilityHidden(true) }
                        Text(variant.actionTitle)
                    }
                    .frame(minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.borderless)
                .disabled(variant.action == .trying)
                .accessibilityIdentifier(variant.actionIdentifier)
            }
            .accessibilityElement(children: .contain)
        }
    }
}

/// Round 28 O1 (D329): the notice's words and the VoiceOver announcements (plan §8; fix round 1's approved copy).
enum OfflineNoticeCopy {
    static let manual = "Offline mode is on"
    static let goOnline = "Go online"
    static let automatic = "Your library is out of reach. Showing music on this phone."
    /// Fix round 1 (design M2, approved): no network path at all.
    static let noConnection = "No connection. Showing music on this phone."
    static let tryAgain = "Try again"
    static let trying = "Trying…"
    /// Fix round 1 (design M1): a Try again that didn't reach the library.
    static let stillOutOfReach = "Still out of reach"
    static let announceOffline = "Offline. Showing music on this phone."
    static let announceOnline = "Back online."
}

enum OfflineCopy {
    /// A page offline whose music isn't on the phone (it was removed, or never downloaded).
    static let notOnPhone = "This isn't on this phone. It'll be here again when you're back online."
}
