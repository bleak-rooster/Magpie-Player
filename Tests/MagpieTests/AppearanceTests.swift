import DesignSystem
import Foundation
import SwiftUI
import MagpieCore
import Testing
@testable import Magpie

@MainActor @Suite struct AppearanceTests {
    private func freshDefaults() -> UserDefaults {
        let name = "appearance-tests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test func themeSwitchUpdatesEnvironment() {
        let defaults = freshDefaults()
        let model = AppModel(store: SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.tests.\(UUID().uuidString)")),
                             matchIndexDirectory: nil, dataDirectory: nil, engine: FakeEngine(), defaults: defaults,
                             systemNowPlaying: false, notifications: false)
        #expect(model.theme.character == .signature)   // the default

        // What RootView does: the model's theme becomes the environment's.
        func environmentCharacter() -> DesignSystem.Character {
            var env = EnvironmentValues()
            env.magpieTheme = model.theme
            return env.magpieTheme.character
        }
        for character in DesignSystem.Character.allCases {
            model.setCharacter(character)
            #expect(model.theme.character == character)
            #expect(environmentCharacter() == character)          // live, no relaunch
            #expect(defaults.string(forKey: "MagpieCharacter") == character.rawValue)
        }
        model.setAccent(.tangerine)
        #expect(model.theme.accent == .tangerine)
        #expect(model.theme.character == .immersive)               // the accent doesn't reset the look

        // A relaunch brings both back.
        #expect(AppModel.savedTheme(defaults) == Theme(character: .immersive, accent: .tangerine))
    }

    @Test func unknownSavedValuesFallBackToDefaults() {
        let defaults = freshDefaults()
        defaults.set("neon", forKey: "MagpieCharacter")
        defaults.set("plaid", forKey: "MagpieAccent")
        #expect(AppModel.savedTheme(defaults) == Theme())
    }

    @Test func scrimHoldsTheLuminanceFloorForAnyArt() {
        let floor = PaletteColor(hex: 0x2A2A2A).relativeLuminance
        #expect(ImmersiveScrim.maxLuminance == floor)
        // The brightest possible art, and a spread of saturated ones.
        for hex: UInt32 in [0xFFFFFF, 0xFFFF00, 0x00FFFF, 0xFF00FF, 0xFF8800, 0x7FFFD4, 0xC0C0C0, 0x000000] {
            let art = PaletteColor(hex: hex)
            #expect(ImmersiveScrim.holdsFloor(forArt: art), "art \(String(hex, radix: 16))")
            #expect(ImmersiveScrim.luminance(underScrimOf: art) <= floor)
        }
        // And the rule can fail: a thinner scrim would not hold for white.
        let thin = PaletteColor(hex: 0x000000, alpha: 0.5).composited(over: PaletteColor(hex: 0xFFFFFF))
        #expect(thin.relativeLuminance > floor)
    }

    @Test func textOnTheScrimKeepsContrast() {
        let under = PaletteColor(hex: 0x000000, alpha: ImmersiveScrim.opacity).composited(over: PaletteColor(hex: 0xFFFFFF))
        for accent in AccentChoice.allCases {
            let p = Theme(character: .immersive, accent: accent).colors(for: .light)   // always dark
            #expect(Contrast.ratio(p.ink, on: under) >= 4.5)
            #expect(Contrast.ratio(p.ink2, on: under) >= 4.5)
            #expect(Contrast.ratio(p.accentInk, on: under) >= 4.5)
            // Capsules and buttons are solid: no art shows through.
            let solid = p.surface.composited(over: p.bg)
            #expect(solid.alpha == 1)
            #expect(Contrast.ratio(p.ink, on: solid) >= 4.5)
        }
    }

    @Test func reduceTransparencyFallsBackToSolid() {
        #expect(ImmersiveBackdropMode.resolve(isImmersive: true, reduceTransparency: false, hasArt: true) == .art)
        #expect(ImmersiveBackdropMode.resolve(isImmersive: true, reduceTransparency: true, hasArt: true) == .solid)
        #expect(ImmersiveBackdropMode.resolve(isImmersive: true, reduceTransparency: false, hasArt: false) == .solid)
        // Classic and Signature never show the art backdrop.
        #expect(ImmersiveBackdropMode.resolve(isImmersive: false, reduceTransparency: false, hasArt: true) == nil)
    }
}
