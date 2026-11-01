import Foundation
import Testing
import UIKit
@testable import Magpie

/// R14: 4 designs x 3 colourways as alternate icons, plus the green cover as the default; all in the built bundle
/// and switchable (AppIconUITests taps the picker, which calls `setAlternateIconName`).
@MainActor @Suite(.serialized) struct AppIconTests {
    static let names = ["RecordForest", "RecordInk", "RecordSunset", "MagpieForest", "MagpieInk", "MagpieSunset",
                        "WaveForest", "WaveInk", "WaveSunset", "NestForest", "NestInk", "NestSunset"]

    @Test func choicesAreTheDefaultPlusTwelve() {
        let choices = AppIconChoice.allCases
        #expect(choices.count == 13)
        #expect(choices.first == .default)
        #expect(choices.first?.iconName == nil)
        #expect(choices.compactMap(\.iconName) == Self.names)
        #expect(Set(choices.map(\.id)).count == 13)
        #expect(AppIconChoice(iconName: "WaveInk") == .alternate(design: .wave, colourway: .ink))
        #expect(AppIconChoice(iconName: nil) == .default)
        #expect(AppIconChoice(iconName: "Nonsense") == .default)
        #expect(AppIconChoice.alternate(design: .record, colourway: .forest).title == "Record, Forest")
    }

    @Test func everyIconIsInTheBuiltBundle() throws {
        let icons = try #require(Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any])
        let alternates = try #require(icons["CFBundleAlternateIcons"] as? [String: Any])
        #expect(Set(alternates.keys) == Set(Self.names))
        let primary = icons["CFBundlePrimaryIcon"] as? [String: Any]
        #expect(primary?["CFBundleIconName"] as? String == "AppIcon")
        // And each has its Settings preview.
        for choice in AppIconChoice.allCases {
            #expect(UIImage(named: choice.previewAsset) != nil, "\(choice.previewAsset)")
        }
        // The switch itself (setAlternateIconName) waits on iOS's alert, so AppIconUITests drives it.
        #expect(UIApplication.shared.supportsAlternateIcons)
    }
}
