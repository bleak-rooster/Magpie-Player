import Foundation
import Testing
import UIKit
@testable import Magpie

/// R14: 4 designs x 3 colourways as alternate icons, plus the green cover as the default; all in the built bundle
/// and switchable (AppIconUITests taps the picker, which calls `setAlternateIconName`). Round 13 (Z6): the green cover
/// also comes in Ink and Sunset (DefaultInk, DefaultSunset), listed right after it so the original family sits together.
@MainActor @Suite(.serialized) struct AppIconTests {
    static let names = ["DefaultInk", "DefaultSunset", "RecordForest", "RecordInk", "RecordSunset", "MagpieForest", "MagpieInk", "MagpieSunset",
                        "WaveForest", "WaveInk", "WaveSunset", "NestForest", "NestInk", "NestSunset"]

    @Test func choicesAreTheDefaultItsTwoColourwaysPlusTwelve() {
        let choices = AppIconChoice.allCases
        #expect(choices.count == 15)
        #expect(choices.first == .default)
        #expect(choices.first?.iconName == nil)
        #expect(choices.compactMap(\.iconName) == Self.names)
        #expect(Set(choices.map(\.id)).count == 15)
        #expect(Array(choices.prefix(3)) == [.default, .original(colourway: .ink), .original(colourway: .sunset)])
        #expect(AppIconChoice(iconName: "DefaultSunset") == .original(colourway: .sunset))
        #expect(AppIconChoice.original(colourway: .ink).id == "DefaultInk")
        #expect(AppIconChoice.original(colourway: .ink).previewAsset == "IconPreview-DefaultInk")
        #expect(AppIconChoice.original(colourway: .ink).title == "Cover, Ink")
        #expect(AppIconChoice.original(colourway: .sunset).title == "Cover, Sunset")
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
