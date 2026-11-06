import AurralKit
import DesignSystem
import SwiftUI

/// Round 23 R23F (D199, D200): "Search again for N missing songs" on a Discover page of one of the user's own flows
/// or Aurral playlists, its confirmation, and its progress and outcome as text with a symbol. Hidden when nothing is
/// missing, while the flow's run is under way, on another user's flow, or when the server can't or the account may
/// not (no dead buttons).
struct SearchAgainSection: View {
    @Environment(AppModel.self) private var model
    let playlistId: String
    /// The flow's run is under way (D61): nothing is offered then.
    let runActive: Bool
    @State private var missing = 0
    @State private var confirming = false
    @State private var sending = false
    @State private var message: String?
    private let themed = Themed()

    private var state: SearchAgainState? { model.searchAgainState(playlistId: playlistId) }
    private var looking: Bool { if case .looking = state { true } else { false } }
    private var count: Int { min(missing, SearchAgain.perTap) }

    var body: some View {
        VStack(spacing: Tokens.Spacing.s) {
            if let state {
                Label(SearchAgainCopy.text(state), systemImage: SearchAgainCopy.symbol(state))
                    .font(.footnote).foregroundStyle(themed.palette.ink2Color)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("discover-search-again-status")
            }
            if model.searchAgainFlow(playlistId: playlistId) != nil, count > 0, !runActive, !looking, !sending,
               state != .notAllowed {
                Button { confirming = true } label: {
                    Label(SearchAgainCopy.button(count), systemImage: SearchAgainCopy.symbol)
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel(SearchAgainCopy.button(count))
                .accessibilityIdentifier("discover-search-again")
            }
        }
        .padding(.horizontal, Tokens.Spacing.l)
        .confirmationDialog(SearchAgainCopy.confirmTitle(count), isPresented: $confirming, titleVisibility: .visible) {
            Button(SearchAgainCopy.confirm) { Task { await send() } }
                .accessibilityIdentifier("discover-search-again-confirm")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(SearchAgainCopy.confirmMessage)
        }
        .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        }
        .task(id: runActive) { await countMissing() }
        // While Aurral is looking: the songs again every 5 s until they settle, then what is still missing.
        .task(id: looking) {
            guard looking else { return }
            while !Task.isCancelled, looking {
                try? await Task.sleep(for: .seconds(5))
                await model.followSearchAgain(playlistId: playlistId)
            }
            if !Task.isCancelled { await countMissing() }
        }
    }

    private func countMissing() async { missing = await model.missingSongs(playlistId: playlistId).count }

    private func send() async {
        sending = true
        defer { sending = false }
        do { try await model.searchAgain(playlistId: playlistId) } catch {
            if (error as? AurralError) != .notPermitted { message = DiscoverCopy.message(for: error) }
        }
        await countMissing()
    }
}
