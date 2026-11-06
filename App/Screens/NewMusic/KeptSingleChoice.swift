import DesignSystem
import Requests
import SwiftUI

/// Round 22 (owner, 2026-11-06, D171): "The single “<title>”": Keep it (the default) or Remove it once the album is here.
/// One Form section, used by the Add sheet after a Keep and by the request page while the bring-in is under way. Each
/// row is a 44 pt button with its state in words and a symbol (D3), one VoiceOver element marked selected.
struct KeptSingleChoice: View {
    let title: String
    @Binding var remove: Bool
    var disabled = false
    private let themed = Themed()

    var body: some View {
        Section {
            row(BringInCopy.keepSingle, on: !remove, id: "kept-single-keep") { remove = false }
            row(BringInCopy.removeSingle, on: remove, id: "kept-single-remove") { remove = true }
        } header: {
            Text(BringInCopy.single(title))
        } footer: {
            Text(remove ? BringInCopy.removeSingleNote : BringInCopy.keepSingleNote)
        }
        .disabled(disabled)
    }

    private func row(_ label: String, on: Bool, id: String, action: @escaping () -> Void) -> some View {
        let p = themed.palette
        return Button(action: action) {
            HStack(spacing: Tokens.Spacing.m) {
                Text(label).foregroundStyle(p.inkColor)
                Spacer(minLength: 0)
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(on ? p.accentInkColor : p.ink2Color)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: Tokens.minHitSize)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityIdentifier(id)
    }
}

/// The request page's part (D171): the choice while the bring-in is under way, then what became of the single.
struct KeptSingleRequestSection: View {
    @Environment(AppModel.self) private var model
    let request: MagpieRequest
    @State private var working = false
    private let themed = Themed()

    var body: some View {
        if let ks = request.keptSingle {
            if ks.isOpen {
                Form {
                    KeptSingleChoice(title: ks.title, remove: Binding(get: { ks.choice == .remove }, set: { remove in
                        Task {
                            working = true
                            await model.setKeptSingle(request.id, remove: remove)
                            working = false
                        }
                    }), disabled: working || model.isOffline)
                }
                .scrollDisabled(true)
                .frame(minHeight: 220)
                .scrollContentBackground(.hidden)
                .accessibilityIdentifier("request-kept-single")
            } else if let outcome = ks.outcome, let text = BringInCopy.singleOutcome(outcome) {
                Label(text, systemImage: outcome == .removed ? "checkmark.circle" : "info.circle")
                    .font(.footnote).foregroundStyle(themed.palette.ink2Color)
                    .padding(.horizontal, Tokens.Spacing.largeTitleMargin)
                    .accessibilityIdentifier("request-kept-single-outcome")
            }
        }
    }
}
