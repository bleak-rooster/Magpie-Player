import DesignSystem
import SwiftUI

/// Settings > Appearance: the Character dial (three cards that re-skin the app live), the accent and the app icon (R14).
struct AppearanceView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let p = model.theme.colors(for: scheme)
        Form {
            Section {
                ForEach(DesignSystem.Character.allCases, id: \.self) { character in
                    CharacterCard(character: character, accent: model.theme.accent, scheme: scheme,
                                  selected: model.theme.character == character) { model.setCharacter(character) }
                }
            } header: {
                Text("Character")
            } footer: {
                Text("Layout and gestures stay the same. Only the look changes.")
            }
            Section {
                HStack(spacing: Tokens.Spacing.l) {
                    ForEach(AccentChoice.allCases, id: \.self) { accent in
                        AccentSwatch(accent: accent, selected: model.theme.accent == accent, scheme: scheme) {
                            model.setAccent(accent)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } header: {
                Text("Accent")
            }
            Section {
                AppIconPicker()
            } header: {
                Text("App icon")
            } footer: {
                Text("Your iPhone confirms the change.")
            }
            Section {
                Label(reduceMotion ? "Reduce Motion is on: records don't spin, and changes fade."
                                   : "Records spin while a song is on its way. Reduce Motion in Settings \u{203A} Accessibility turns that off.",
                      systemImage: "figure.walk.motion")
                    .font(.footnote)
                if model.theme.character == .immersive, reduceTransparency {
                    Label("Reduce Transparency is on: Immersive uses a solid background instead of album art.",
                          systemImage: "circle.lefthalf.filled")
                        .font(.footnote)
                }
            } footer: {
                Text("Magpie follows your iPhone's accessibility settings.")
            }
        }
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(p.bgColor.ignoresSafeArea())
        .tint(p.accentInkColor)
    }
}

enum CharacterCopy {
    static func title(_ c: DesignSystem.Character) -> String {
        switch c {
        case .classic: "Classic"
        case .signature: "Signature"
        case .immersive: "Immersive"
        }
    }

    static func blurb(_ c: DesignSystem.Character) -> String {
        switch c {
        case .classic: "Stock iOS. System type and colours."
        case .signature: "Warm paper and ink, with a serif voice."
        case .immersive: "Album art sets the colours, with bolder type. Always dark."
        }
    }
}

/// One position on the dial, drawn in its own palette so you can see it before you pick it.
private struct CharacterCard: View {
    let character: DesignSystem.Character
    let accent: AccentChoice
    let scheme: ColorScheme
    let selected: Bool
    let choose: () -> Void

    var body: some View {
        let theme = Theme(character: character, accent: accent)
        let p = theme.colors(for: scheme)
        Button(action: choose) {
            HStack(spacing: Tokens.Spacing.m) {
                VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                    Text(CharacterCopy.title(character)).font(theme.displayFont(.headline)).foregroundStyle(p.inkColor)
                    Text(CharacterCopy.blurb(character)).font(.footnote).foregroundStyle(p.ink2Color)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if selected {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(p.accentInkColor)
                }
            }
            .padding(Tokens.Spacing.m)
            .frame(minHeight: Tokens.minHitSize)
            .background(p.bgColor, in: RoundedRectangle(cornerRadius: Tokens.Radius.card / 2, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.card / 2, style: .continuous)
                .strokeBorder(selected ? p.accentInkColor : p.sepColor, lineWidth: selected ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.clear)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("character-\(character.rawValue)")
    }
}

struct AccentSwatch: View {
    let accent: AccentChoice
    let selected: Bool
    let scheme: ColorScheme
    let choose: () -> Void

    var body: some View {
        let tokens = Theme(accent: accent).colors(for: scheme)
        Button(action: choose) {
            VStack(spacing: Tokens.Spacing.xs) {
                Circle().fill(tokens.accentColor).frame(width: 32, height: 32)
                    .overlay {
                        if selected {
                            Image(systemName: "checkmark").font(.footnote.weight(.bold)).foregroundStyle(tokens.onAccentColor)
                        }
                    }
                Text(Self.name(accent)).font(.caption).foregroundStyle(.primary)
            }
            .frame(minWidth: Tokens.minHitSize, minHeight: Tokens.minHitSize)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Self.name(accent))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("accent-\(accent.rawValue)")
    }

    static func name(_ a: AccentChoice) -> String {
        switch a {
        case .sheen: "Sheen"
        case .tangerine: "Tangerine"
        case .ultramarine: "Ultramarine"
        }
    }
}
