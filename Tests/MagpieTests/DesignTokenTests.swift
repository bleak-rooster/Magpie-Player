import Testing
import SwiftUI
import MagpieCore
import DesignSystem

@Suite struct DesignTokenTests {
    @Test func textPairsMeetContrast() {
        var failures: [String] = []
        for character in DesignSystem.Character.allCases {
            for accent in AccentChoice.allCases {
                for scheme in [ColorScheme.light, .dark] {
                    let p = Theme(character: character, accent: accent).colors(for: scheme)
                    let pairs: [(String, Double)] = [
                        ("ink/bg", Contrast.ratio(p.ink, on: p.bg)),
                        ("ink2/bg", Contrast.ratio(p.ink2, on: p.bg)),
                        ("accentInk/bg", Contrast.ratio(p.accentInk, on: p.bg)),
                        ("onAccent/accent", Contrast.ratio(p.onAccent, on: p.accent)),
                    ]
                    for (name, ratio) in pairs where ratio < 4.5 {
                        failures.append("\(character) \(accent) \(scheme) \(name) = \(ratio)")
                    }
                }
            }
        }
        #expect(failures.isEmpty, "\(failures)")
    }

    @Test func paletteHexesMatchDesignLanguage() {
        let sigLight = Theme(character: .signature, accent: .sheen).colors(for: .light)
        #expect(sigLight.bg == PaletteColor(hex: 0xFBFAF7))
        #expect(sigLight.ink == PaletteColor(hex: 0x16130F))
        #expect(sigLight.accent == PaletteColor(hex: 0x3CC4B8))
        #expect(sigLight.accentInk == PaletteColor(hex: 0x0E6F68))
        #expect(sigLight.onAccent == PaletteColor(hex: 0x04201D))
        let classicDark = Theme(character: .classic, accent: .sheen).colors(for: .dark)
        #expect(classicDark.bg == PaletteColor(hex: 0x000000))
        #expect(classicDark.surface == PaletteColor(hex: 0x1C1C1E))
        #expect(classicDark.accentInk == PaletteColor(hex: 0x3CC4B8))
        let tangerine = Theme(character: .classic, accent: .tangerine).colors(for: .light)
        #expect(tangerine.accent == PaletteColor(hex: 0xF25C05))
        #expect(tangerine.accentInk == PaletteColor(hex: 0xC2410C))
        let ultra = Theme(character: .classic, accent: .ultramarine).colors(for: .dark)
        #expect(ultra.accent == PaletteColor(hex: 0x3D5AFE))
        #expect(ultra.accentInk == PaletteColor(hex: 0x8C9EFF))
    }

    @Test func immersiveIsAlwaysDark() {
        let t = Theme(character: .immersive, accent: .sheen)
        #expect(t.colors(for: .light) == t.colors(for: .dark))
    }

    @Test func findSaturationClamps() {
        #expect(RowState.findSaturation(daysLeft: 7) == 1.0)
        #expect(RowState.findSaturation(daysLeft: 14) == 1.0)
        #expect(abs(RowState.findSaturation(daysLeft: 3) - 3.0 / 7.0) < 1e-9)
        #expect(RowState.findSaturation(daysLeft: 0) == 0.05)
        #expect(RowState.findSaturation(daysLeft: -2) == 0.05)
        #expect(RowState.find(daysLeft: 7).saturation == 1.0)
        #expect(RowState.library.saturation == 1.0)
    }

    @Test func rowStateVoiceOverValues() {
        #expect(RowState.library.voiceOverValue == nil)
        #expect(RowState.downloaded.voiceOverValue == "Downloaded")
        #expect(RowState.notYet.voiceOverValue == "Not in your library")
        #expect(RowState.find(daysLeft: 3).voiceOverValue == "Find, 3 days left to keep")
        #expect(RowState.find(daysLeft: 1).voiceOverValue == "Find, 1 day left to keep")
        #expect(RowState.find(daysLeft: 0).voiceOverValue == "Find, leaves today")
        #expect(RowState.onItsWay(progress: 0.4, phrase: "about 30 seconds").voiceOverValue == "Bringing it home, 40 percent")
        #expect(RowState.onItsWay(progress: nil, phrase: "about 30 seconds").voiceOverValue == "Bringing it home, about 30 seconds")
        #expect(RowState.newFind.voiceOverValue == "New find")
        #expect(RowState.keptLosslessSoon.voiceOverValue == "In your library, lossless on the way")
        #expect(RowState.lossless.voiceOverValue == "In your library, lossless")
        #expect(RowState.notFound.voiceOverValue == "Still looking, we'll tell you when it's here")
    }

    @Test func rowStateShapeAndCues() {
        for s in [RowState.notYet, .find(daysLeft: 2), .newFind, .notFound, .onItsWay(progress: nil, phrase: "")] {
            #expect(s.isRecord)
            #expect(s.statusSymbol != nil)          // D3/D15: never shape alone
            #expect(!s.statusText.isEmpty)
        }
        for s in [RowState.library, .downloaded, .keptLosslessSoon, .lossless] { #expect(!s.isRecord) }
        #expect(RowState.library.statusSymbol == nil)
    }

    @Test func songRowAccessibilityLabelAndActions() {
        let song = Song(id: "1", title: "Harbour Lights", artist: "Corin Hale", album: "A", duration: 200)
        #expect(SongRow.accessibilityLabel(for: song) == "Harbour Lights, Corin Hale")
        #expect(RowState.notYet.accessibilityActionNames == ["Try"])
        #expect(RowState.find(daysLeft: 4).accessibilityActionNames == ["Keep"])
        #expect(RowState.newFind.accessibilityActionNames == ["Keep"])
        #expect(RowState.library.accessibilityActionNames.isEmpty)
    }

    @Test func hallmarkAndHitArea() {
        #expect(Hallmark.text(for: .sample) == "Sample")
        #expect(Hallmark.text(for: .losslessSoon) == "Lossless soon")
        #expect(Hallmark.text(for: .hiRes) == "Hi-Res")
        #expect(Hallmark.text(for: .standard) == nil)
        #expect(Hallmark.accessibilityText(for: .hiRes) == "High-resolution lossless")
        #expect(CapsuleButton.minimumHitSize >= 44)
    }

    @Test func hintsAlwaysHaveADefaultAction() {
        let all: [RowState] = [.library, .downloaded, .notYet, .onItsWay(progress: nil, phrase: ""), .newFind,
                               .find(daysLeft: 3), .keptLosslessSoon, .lossless, .notFound]
        for s in all { #expect((s.accessibilityHint != nil) == (s.primaryAction != nil), "\(s)") }
        #expect(RowState.notYet.primaryAction == .try)
        #expect(RowState.notYet.accessibilityHint == "Double-tap to try it.")
    }
}
