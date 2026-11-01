import DesignSystem
import SwiftUI

extension View {
    /// The library's notices ("Added to Road trip", a favourite that didn't go through, "You're offline") as a small
    /// banner at the top for a few seconds, also announced to VoiceOver. Any screen over the root (Now Playing) can
    /// show them too.
    func libraryNotices() -> some View { modifier(LibraryNotices()) }
}

private struct LibraryNotices: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let themed = Themed()

    func body(content: Content) -> some View {
        let notice = model.libraryEdits.notice
        content
            .overlay(alignment: .top) {
                if let notice {
                    Label(notice.text, systemImage: notice.symbol)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(themed.palette.inkColor)
                        .padding(.horizontal, Tokens.Spacing.l).padding(.vertical, Tokens.Spacing.s)
                        .frame(minHeight: Tokens.minHitSize)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.horizontal, Tokens.Spacing.margin)
                        .padding(.top, Tokens.Spacing.s)
                        .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                        .onTapGesture { model.libraryEdits.notice = nil }
                        .accessibilityIdentifier("library-notice")
                }
            }
            .animation(reduceMotion ? nil : .snappy, value: notice)
            .task(id: notice?.id) {
                guard let notice else { return }
                AccessibilityNotification.Announcement(notice.text).post()
                try? await Task.sleep(for: notice.shown)
                if model.libraryEdits.notice?.id == notice.id { model.libraryEdits.notice = nil }
            }
    }
}
