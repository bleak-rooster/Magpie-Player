import DesignSystem
import Foundation

extension AppModel {
    nonisolated static let characterKey = "MagpieCharacter"
    nonisolated static let accentKey = "MagpieAccent"

    /// The look the user chose last time; anything unknown falls back to Signature + Sheen.
    static func savedTheme(_ defaults: UserDefaults) -> Theme {
        var theme = Theme()
        if let raw = defaults.string(forKey: characterKey), let c = DesignSystem.Character(rawValue: raw) { theme.character = c }
        if let raw = defaults.string(forKey: accentKey), let a = AccentChoice(rawValue: raw) { theme.accent = a }
        return theme
    }

    /// Settings > Appearance > Character. Applies at once (RootView reads `theme`) and is remembered.
    func setCharacter(_ character: DesignSystem.Character) {
        guard theme.character != character else { return }
        theme.character = character
        appDefaults.set(character.rawValue, forKey: Self.characterKey)
    }

    func setAccent(_ accent: AccentChoice) {
        guard theme.accent != accent else { return }
        theme.accent = accent
        appDefaults.set(accent.rawValue, forKey: Self.accentKey)
    }
}
