import AurralKit
import DesignSystem
import SwiftUI

extension View {
    /// Round 24 C (D212): a Discover page's More menu (Delete flow / Delete playlist on the user's own), its
    /// confirmation, and the delete's progress.
    func aurralItemMenu(playlistId: String) -> some View { modifier(AurralItemMenu(playlistId: playlistId)) }
}

/// Round 24 C (owner, 2026-11-08: "Delete Aurral playlists and flows"; D212, ruling Q4). The toolbar's ⋯ menu on a
/// Discover page shows only while something in it can work: Delete flow or Delete playlist, on the user's own flow or
/// Aurral playlist, online, with Aurral's manage routes and accessFlow (`deletableAurralItem`). The confirmation names
/// it and says what goes; then "Aurral is removing it…" under the page until Aurral has run the delete (read every 5 s,
/// at most `aurralRemovalLimit`, then "Aurral is still removing it."), and "Deleted “<name>”." closes the page.
private struct AurralItemMenu: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let playlistId: String
    @State private var confirming: AurralItemToDelete?
    @State private var sending = false
    @State private var still = false
    @State private var message: String?
    @State private var closes = false
    private let themed = Themed()

    private var removal: AurralRemoval? { model.aurralRemoval(playlistId: playlistId) }

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if let item = model.deletableAurralItem(playlistId: playlistId), !sending {
                        Menu {
                            Button(AurralDeleteCopy.menuItem(item.kind), systemImage: "trash", role: .destructive) {
                                confirming = item
                            }
                            .accessibilityIdentifier("discover-delete")
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .frame(minWidth: Tokens.minHitSize, minHeight: Tokens.minHitSize)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel("More")
                        .accessibilityIdentifier("discover-more")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if removal != nil || sending {
                    Label(still ? AurralDeleteCopy.stillRemoving : AurralDeleteCopy.removing,
                          systemImage: still ? "clock.badge.exclamationmark" : "trash")
                        .font(.footnote)
                        .foregroundStyle(themed.palette.ink2Color)
                        .frame(maxWidth: .infinity, minHeight: Tokens.minHitSize)
                        .background(.bar)
                        .accessibilityIdentifier("discover-removing")
                }
            }
            .confirmationDialog(confirming.map { AurralDeleteCopy.title($0.name) } ?? "",
                                isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                                titleVisibility: .visible, presenting: confirming) { item in
                Button(AurralDeleteCopy.confirm, role: .destructive) { Task { await delete(item) } }
                    .accessibilityIdentifier("discover-delete-confirm")
                Button(AurralDeleteCopy.keep, role: .cancel) {}
            } message: { item in
                Text(AurralDeleteCopy.message(item.kind))
            }
            .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK", role: .cancel) { if closes { dismiss() } }
            }
            // While Aurral hasn't run the delete: a fresh look every 5 s, for at most `aurralRemovalLimit`.
            .task(id: removal?.item.id) {
                guard let removal else { return }
                still = false
                while !Task.isCancelled {
                    switch await model.checkAurralRemoval(playlistId: playlistId) {
                    case .deleted?: finished(removal.item.name); return
                    case .stillRemoving?: still = true; return
                    case .removing?: break
                    case nil: return
                    }
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                }
            }
    }

    private func delete(_ item: AurralItemToDelete) async {
        sending = true
        defer { sending = false }
        do {
            if try await model.deleteAurralItem(playlistId: playlistId) == .deleted { finished(item.name) }
        } catch {
            message = AurralDeleteCopy.failed
        }
    }

    private func finished(_ name: String) {
        closes = true
        message = AurralDeleteCopy.deleted(name)
    }
}
