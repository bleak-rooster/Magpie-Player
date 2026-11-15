import DesignSystem
import SwiftUI

/// The offline notice, as text with its symbol (D3), on the screens offline mode changes (Task 14).
/// Round 28 O1 (owner, 2026-11-15, D329): it says who chose it. Offline mode on: "Offline mode is on" and Go online;
/// offline by itself: "Your library is out of reach…" and Try again ("Trying…" while a check runs). Nothing while
/// Magpie is only checking (suspect). It never animates; VoiceOver hears each switch once, from `AppModel`, not from
/// each notice on screen. `AppModel.offlineCopy` ("You're offline") stays the refusal everywhere else (D139).
struct OfflineNotice: View {
    @Environment(AppModel.self) private var model
    private let themed = Themed()

    var body: some View {
        content
            .transaction { $0.animation = nil }
    }

    /// What the notice shows in each state: nil while online or only checking.
    struct Variant: Equatable {
        enum Action: Equatable { case goOnline, tryAgain, trying }
        var text: String
        var symbol: String
        var action: Action
        var actionTitle: String
        var actionIdentifier: String
    }

    static func variant(_ state: OfflineState, checking: Bool) -> Variant? {
        switch state {
        case .manual:
            Variant(text: OfflineNoticeCopy.manual, symbol: "wifi.slash", action: .goOnline,
                    actionTitle: OfflineNoticeCopy.goOnline, actionIdentifier: "offline-go-online")
        case .automatic:
            Variant(text: OfflineNoticeCopy.automatic, symbol: "wifi.exclamationmark", action: checking ? .trying : .tryAgain,
                    actionTitle: checking ? OfflineNoticeCopy.trying : OfflineNoticeCopy.tryAgain,
                    actionIdentifier: "offline-try-again")
        case .online, .suspect:
            nil
        }
    }

    @ViewBuilder private var content: some View {
        if let variant = Self.variant(model.offlineState, checking: model.reachability.checking) {
            notice(variant.text, symbol: variant.symbol) {
                Button {
                    switch variant.action {
                    case .goOnline: model.goOnline()
                    case .tryAgain: Task { await model.reconnectNow() }
                    case .trying: break
                    }
                } label: {
                    HStack(spacing: 6) {
                        if variant.action == .trying { ProgressView().accessibilityHidden(true) }
                        Text(variant.actionTitle)
                    }
                }
                .disabled(variant.action == .trying)
                .accessibilityIdentifier(variant.actionIdentifier)
            }
        }
    }

    /// The line, then its one action (borderless, so in a list only the button acts; 44 pt tall).
    private func notice(_ text: String, symbol: String, @ViewBuilder action: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(text, systemImage: symbol)
                .font(.subheadline)
                .foregroundStyle(themed.palette.ink2Color)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("offline-notice")
            action()
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.borderless)
                .frame(minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
        }
        .accessibilityElement(children: .contain)
    }
}

/// Round 28 O1 (D329): the notice's words and the VoiceOver announcements (plan §8).
enum OfflineNoticeCopy {
    static let manual = "Offline mode is on"
    static let goOnline = "Go online"
    static let automatic = "Your library is out of reach. Showing music on this phone."
    static let tryAgain = "Try again"
    static let trying = "Trying…"
    static let announceOffline = "Offline. Showing music on this phone."
    static let announceOnline = "Back online."
}

enum OfflineCopy {
    /// A page offline whose music isn't on the phone (it was removed, or never downloaded).
    static let notOnPhone = "This isn't on this phone. It'll be here again when you're back online."
}
