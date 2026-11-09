import DesignSystem
import SwiftUI

/// Round 24 (owner, 2026-11-08): who made a playlist or flow, said subtly under its name when everyone's are shown
/// (plan item b, owner item 3; D223). A small grey footnote with a person symbol ("jordan"), read by VoiceOver as
/// "made by jordan". Nothing for your own (compared as Yours compares owners, D101: case-insensitively) or when the
/// owner isn't known. Used by Playlists › All (here); Aurral's rows (round 24 A) and the car's row detail (F) use
/// `text(owner:signedInUser:)` so all three say the same.
struct OwnerCaption: View {
    let owner: String?
    let signedInUser: String?
    private let themed = Themed()

    init(owner: String?, signedInUser: String?) {
        self.owner = owner
        self.signedInUser = signedInUser
    }

    /// The SF Symbol beside the name: state is text plus a symbol, never colour alone (D3).
    static let symbol = "person"

    /// The name to show, or nil for your own, an unknown owner, or a blank one. Shown trimmed; when the signed-in
    /// user isn't known, the owner isn't known to be yours, so it shows.
    static func text(owner: String?, signedInUser: String?) -> String? {
        guard let name = owner?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        if let me = signedInUser?.trimmingCharacters(in: .whitespacesAndNewlines), !me.isEmpty,
           name.caseInsensitiveCompare(me) == .orderedSame { return nil }
        return name
    }

    /// What VoiceOver says for it ("made by jordan"), or nil when nothing shows.
    static func accessibilityText(owner: String?, signedInUser: String?) -> String? {
        text(owner: owner, signedInUser: signedInUser).map { "made by \($0)" }
    }

    var text: String? { Self.text(owner: owner, signedInUser: signedInUser) }
    var accessibilityText: String? { Self.accessibilityText(owner: owner, signedInUser: signedInUser) }

    var body: some View {
        if let text, let accessibilityText {
            Label(text, systemImage: Self.symbol)
                .labelStyle(.titleAndIcon)
                .font(.footnote)
                .foregroundStyle(themed.palette.ink2Color)
                .lineLimit(1)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityText)
                .accessibilityIdentifier("owner-caption")
        }
    }
}
