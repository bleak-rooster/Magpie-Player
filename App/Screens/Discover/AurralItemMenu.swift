import AurralKit
import DesignSystem
import SwiftUI

extension View {
    /// Round 24 C (D212): a Discover page's More menu (Delete flow / Delete playlist on the user's own), its
    /// confirmation, and the delete's progress. Its words go out through the page's own alert (`message`, fix round 1
    /// M5), so a page has one alert.
    func aurralItemMenu(playlistId: String, message: Binding<String?>) -> some View {
        modifier(AurralItemMenu(playlistId: playlistId, message: message))
    }
}

/// Round 24 C (owner, 2026-11-08: "Delete Aurral playlists and flows"; D212, ruling Q4). The toolbar's ⋯ menu on a
/// Discover page shows only while something in it can work: Delete flow or Delete playlist, on the user's own flow or
/// Aurral playlist, online, with Aurral's manage routes and accessFlow (`deletableAurralItem`). The confirmation names
/// it and says what goes, and what it confirmed is what is sent (fix round 1, I6). Then "Aurral is removing it…" under
/// the page until Aurral has run the delete: read every 5 s while the app is in front (M4), at most
/// `aurralRemovalLimit`, then "Aurral is still removing it." and Delete is offered again. "Deleted “<name>”." closes the
/// page; a 404 says "It's no longer in Aurral." (B-L1); a lost answer says Magpie couldn't hear back and keeps
/// checking (I1).
private struct AurralItemMenu: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    let playlistId: String
    @Binding var message: String?
    @State private var confirming: AurralItemToDelete?
    @State private var sending = false
    @State private var closes = false

    private var removal: AurralRemoval? { model.aurralRemoval(playlistId: playlistId) }
    /// The delete to follow, and whether the app is in front (M4: the loop pauses in the background).
    private var follow: String { "\(removal?.item.id ?? "")|\(scenePhase == .active)" }

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
                    Label(AurralDeleteCopy.removing, systemImage: "trash")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: Tokens.minHitSize)
                        .background(.bar)
                        .accessibilityIdentifier("discover-removing")
                }
            }
            .confirmationDialog(confirming.map { AurralDeleteCopy.title($0.name) } ?? "",
                                isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                                titleVisibility: .visible, presenting: confirming) { item in
                Button(AurralDeleteCopy.confirm, role: .destructive) { Task { await delete(item) } }
                    .disabled(sending)
                    .accessibilityIdentifier("discover-delete-confirm")
                Button(AurralDeleteCopy.keep, role: .cancel) {}
            } message: { item in
                Text(AurralDeleteCopy.message(item.kind))
            }
            // The page's alert was dismissed after "Deleted": the page goes too.
            .onChange(of: message) { if message == nil, closes { dismiss() } }
            .task(id: follow) {
                guard let removal, scenePhase == .active else { return }
                while !Task.isCancelled {
                    switch await model.checkAurralRemoval(playlistId: playlistId) {
                    case .deleted?: finished(AurralDeleteCopy.deleted(removal.item.name)); return
                    case .stillRemoving?: message = AurralDeleteCopy.stillRemoving; return
                    case nil: return
                    default: break
                    }
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                }
            }
    }

    private func delete(_ item: AurralItemToDelete) async {
        guard !sending else { return }
        sending = true
        defer { sending = false }
        do {
            switch try await model.deleteAurralItem(playlistId: playlistId, confirmed: item) {
            case .alreadyGone: finished(AurralDeleteCopy.alreadyGone)
            case .unheard: message = AurralDeleteCopy.unheard
            default: break   // queued: followed above
            }
        } catch {
            message = AurralDeleteCopy.message(for: error)
        }
    }

    private func finished(_ words: String) {
        closes = true
        message = words
    }
}
