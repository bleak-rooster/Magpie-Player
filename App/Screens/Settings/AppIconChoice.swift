import DesignSystem
import SwiftUI
import UIKit

/// R14: the app icons Settings › Appearance › App icon offers. `default` is the green cover (AppIcon); the others are
/// 4 designs x 3 colourways, rendered by scripts/render-alternate-icons.swift and listed in project.yml's
/// ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES. Round 13: `original` is the green cover recoloured in Ink or Sunset
/// (DefaultInk, DefaultSunset; scripts/render-app-icon.swift), listed right after the default.
enum AppIconChoice: Hashable, CaseIterable, Identifiable {
    case `default`
    /// The green cover in another colourway (Forest is `default` itself).
    case original(colourway: Colourway)
    case alternate(design: Design, colourway: Colourway)

    enum Design: String, CaseIterable { case record = "Record", magpie = "Magpie", wave = "Wave", nest = "Nest" }
    enum Colourway: String, CaseIterable { case forest = "Forest", ink = "Ink", sunset = "Sunset" }

    static var allCases: [AppIconChoice] {
        [.default, .original(colourway: .ink), .original(colourway: .sunset)] + Design.allCases.flatMap { d in Colourway.allCases.map { .alternate(design: d, colourway: $0) } }
    }

    var id: String { iconName ?? "Default" }

    /// The asset catalog's alternate icon name; nil for the primary icon.
    var iconName: String? {
        switch self {
        case .default: nil
        case .original(let colourway): "Default" + colourway.rawValue
        case .alternate(let design, let colourway): design.rawValue + colourway.rawValue
        }
    }

    init(iconName: String?) {
        self = Self.allCases.first { $0.iconName == iconName } ?? .default
    }

    /// The small preview image in the asset catalog.
    var previewAsset: String { "IconPreview-\(id)" }

    /// VoiceOver and the caption: "Record, Forest".
    var title: String {
        switch self {
        case .default: "Green cover"
        case .original(let colourway): "Cover, \(colourway.rawValue)"
        case .alternate(let design, let colourway): "\(design.rawValue), \(colourway.rawValue)"
        }
    }
}

/// The system's alternate-icon calls, behind a seam so the picker can be tested without the system alert.
@MainActor
protocol AppIconSetting {
    var supportsAlternateIcons: Bool { get }
    var alternateIconName: String? { get }
    func setAlternateIconName(_ name: String?) async throws
}

extension UIApplication: AppIconSetting {}

/// Settings › Appearance › App icon: a grid of previews; a tap switches the Home Screen icon (iOS confirms it).
struct AppIconPicker: View {
    let setting: AppIconSetting
    @State private var current: AppIconChoice = .default
    @State private var failed = false
    private let themed = Themed()

    init(setting: AppIconSetting = UIApplication.shared) { self.setting = setting }

    var body: some View {
        let p = themed.palette
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: Tokens.Spacing.m)], spacing: Tokens.Spacing.m) {
                ForEach(AppIconChoice.allCases) { choice in
                    Button { Task { await choose(choice) } } label: {
                        Image(choice.previewAsset).resizable().scaledToFit()
                            .frame(width: 60, height: 60)
                            .clipShape(RoundedRectangle(cornerRadius: 13.4, style: .continuous))
                            .padding(3)
                            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(current == choice ? p.accentInkColor : .clear, lineWidth: 2.5))
                            .frame(minWidth: Tokens.minHitSize, minHeight: Tokens.minHitSize)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(choice.title)
                    .accessibilityAddTraits(current == choice ? .isSelected : [])
                    .accessibilityIdentifier("app-icon-\(choice.id)")
                }
            }
            if failed {
                Label("Couldn't change the icon. Try again in a moment.", systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(p.ink2Color)
            }
        }
        .disabled(!setting.supportsAlternateIcons)
        .onAppear { current = AppIconChoice(iconName: setting.alternateIconName) }
    }

    private func choose(_ choice: AppIconChoice) async {
        guard choice != current else { return }
        do {
            try await setting.setAlternateIconName(choice.iconName)
            current = choice
            failed = false
        } catch {
            failed = true
        }
    }
}
