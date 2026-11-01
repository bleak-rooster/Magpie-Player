import DesignSystem
import Foundation
import MagpieCore
import SwiftUI
import Testing
import UIKit
@testable import Magpie

/// R13: Immersive is its own theme. Its colours come from the cover (extracted on the phone, cached per cover id,
/// AA-checked with a fallback to the theme accent), and it has its own type: New York at bolder, larger display sizes,
/// SF Pro Compressed accents and SF Mono numbers. Increase Contrast keeps the fixed palette (D15).
@MainActor @Suite(.serialized) struct ImmersiveLookTests {
    /// An RGBA8 bitmap: `parts` colours, each filling `count` pixels, in order.
    static func bitmap(_ parts: [(hex: UInt32, count: Int)], alpha: UInt8 = 255) -> [UInt8] {
        parts.flatMap { part in
            Array(repeating: [UInt8((part.hex >> 16) & 0xFF), UInt8((part.hex >> 8) & 0xFF), UInt8(part.hex & 0xFF), alpha],
                  count: part.count).flatMap { $0 }
        }
    }

    // MARK: Extraction

    @Test func extractionIsDeterministicForFixtures() throws {
        // 70% brick red, 30% cornflower blue: red dominates, blue is the accent (a hue of its own).
        let pixels = Self.bitmap([(0xC0392B, 70), (0x2E86DE, 30)])
        let a = try #require(ArtPalette.extract(rgba: pixels, width: 10, height: 10))
        #expect(a.dominant == PaletteColor(hex: 0xC0392B))
        #expect(a.accent == PaletteColor(hex: 0x2E86DE))
        // Same answer every time, and whatever the pixel order.
        #expect(ArtPalette.extract(rgba: pixels, width: 10, height: 10) == a)
        let reversed = Self.bitmap([(0x2E86DE, 30), (0xC0392B, 70)])
        #expect(ArtPalette.extract(rgba: reversed, width: 10, height: 10) == a)

        // A grey cover with one small vivid spot: grey dominates, the spot is the accent.
        let grey = try #require(ArtPalette.extract(rgba: Self.bitmap([(0x808080, 90), (0xF39C12, 10)]), width: 10, height: 10))
        #expect(grey.dominant == PaletteColor(hex: 0x808080))
        #expect(grey.accent == PaletteColor(hex: 0xF39C12))

        // All grey: no accent of its own, so the theme's stays.
        let mono = try #require(ArtPalette.extract(rgba: Self.bitmap([(0x202020, 50), (0xE0E0E0, 50)]), width: 10, height: 10))
        #expect(mono.accentTokens == nil)
        #expect(Theme(character: .immersive, accent: .sheen, art: mono).colors(for: .dark).accent == PaletteColor(hex: 0x3CC4B8))

        // Transparent pixels don't count; an empty or short bitmap has no palette.
        #expect(ArtPalette.extract(rgba: Self.bitmap([(0xFF0000, 4)], alpha: 0), width: 2, height: 2) == nil)
        #expect(ArtPalette.extract(rgba: [1, 2, 3], width: 2, height: 2) == nil)
    }

    @Test func artTokensPassAAOrFallBack() throws {
        // Covers from very dark to very light, saturated and not.
        let covers: [UInt32] = [0x000000, 0xFFFFFF, 0x0A0A40, 0x1B4332, 0xC0392B, 0x2E86DE, 0xF1C40F, 0x8E44AD, 0x00FFFF,
                                0x3B2F2F, 0x7F7F80, 0xFF00FF, 0x0000FF, 0x101010]
        let floor = ImmersiveScrim.floor
        var fallbacks = 0
        for dominant in covers {
            for accent in covers {
                let art = ArtPalette(dominant: PaletteColor(hex: dominant), accent: PaletteColor(hex: accent))
                let label = "\(String(dominant, radix: 16))/\(String(accent, radix: 16))"
                // Backgrounds stay under the floor, so every text pair validated there holds.
                #expect(art.background.relativeLuminance <= ImmersiveScrim.maxLuminance, "\(label)")
                #expect(art.glow.relativeLuminance <= ImmersiveScrim.maxLuminance, "\(label)")
                let p = Theme(character: .immersive, accent: .sheen, art: art).colors(for: .light)
                for (name, fg) in [("ink", p.ink), ("ink2", p.ink2), ("accentInk", p.accentInk)] {
                    #expect(Contrast.ratio(fg, on: floor) >= 4.5, "\(label) \(name) on floor")
                    #expect(Contrast.ratio(fg, on: p.bg) >= 4.5, "\(label) \(name) on bg")
                }
                #expect(Contrast.ratio(p.onAccent, on: p.accent) >= 4.5, "\(label) onAccent")
                #expect(Contrast.ratio(p.accent, on: p.bg) >= 3, "\(label) accent fill on bg")
                if art.accentTokens == nil {
                    fallbacks += 1
                    #expect(p.accent == PaletteColor(hex: 0x3CC4B8), "\(label) falls back to Sheen")
                }
            }
        }
        #expect(fallbacks > 0)   // grey covers do fall back

        // A colourful cover really does colour the theme.
        let blue = ArtPalette(dominant: PaletteColor(hex: 0x1B2A49), accent: PaletteColor(hex: 0x2E86DE))
        let tokens = try #require(blue.accentTokens)
        let p = Theme(character: .immersive, accent: .sheen, art: blue).colors(for: .dark)
        #expect(p.accentInk == tokens.ink)
        #expect(p.bg == blue.background)
        #expect(p.accentInk.blue > p.accentInk.red)
        #expect(ArtPalette.passesAA(tokens.ink))
    }

    @Test func gradientOverScrimmedWhiteArtHoldsTheFloor() {
        // Mixing colours that each sit under the floor never rises above it (luminance is convex in sRGB).
        let art = ArtPalette(dominant: PaletteColor(hex: 0xF1C40F), accent: PaletteColor(hex: 0x00FFFF))
        let scrimmed = PaletteColor(hex: 0x000000, alpha: ImmersiveScrim.opacity).composited(over: PaletteColor(hex: 0xFFFFFF))
        for layer in [art.glow, art.background] {
            for alpha in stride(from: 0.0, through: 1.0, by: 0.1) {
                var c = layer; c.alpha = alpha
                #expect(c.composited(over: scrimmed).relativeLuminance <= ImmersiveScrim.maxLuminance)
            }
        }
    }

    @Test func otherCharactersIgnoreArtAndIncreaseContrastFallsBack() {
        let art = ArtPalette(dominant: PaletteColor(hex: 0xC0392B), accent: PaletteColor(hex: 0x2E86DE))
        for character in [DesignSystem.Character.classic, .signature] {
            let base = Theme(character: character, accent: .tangerine)
            #expect(ImmersiveArt.theme(base, art: art, increaseContrast: false) == base)
            #expect(Theme(character: character, accent: .tangerine, art: art).colors(for: .light) == base.colors(for: .light))
        }
        let immersive = Theme(character: .immersive, accent: .tangerine)
        #expect(ImmersiveArt.theme(immersive, art: art, increaseContrast: false).art == art)
        // Increase Contrast: the fixed Immersive palette, the user's own accent.
        let high = ImmersiveArt.theme(immersive, art: art, increaseContrast: true)
        #expect(high.art == nil)
        #expect(high.colors(for: .dark) == immersive.colors(for: .dark))
    }

    // MARK: Cache

    @Test func paletteCacheIsKeyedByCoverId() async throws {
        let cache = ArtPaletteCache()
        final class Loads { var ids: [String] = [] }
        let log = Loads()
        let red = Self.image(0xC0392B), blue = Self.image(0x2E86DE)
        let a = await cache.palette(for: "al-1") { log.ids.append("al-1"); return red }
        let again = await cache.palette(for: "al-1") { log.ids.append("al-1"); return blue }
        let b = await cache.palette(for: "al-2") { log.ids.append("al-2"); return blue }
        #expect(log.ids == ["al-1", "al-2"])   // the second ask for al-1 never loaded
        #expect(a == again)
        #expect(a != b)
        #expect(cache.cached("al-1") == a)
        #expect(cache.cached("al-2") == b)
        #expect(cache.cached("al-3") == nil)
        let aDominant = try #require(a?.dominant)
        #expect(abs(aDominant.red - 0xC0 / 255.0) < 0.02)

        // Reload artwork forgets one cover; sign-in/out forgets them all.
        cache.remove("al-1")
        #expect(cache.cached("al-1") == nil)
        #expect(cache.cached("al-2") == b)
        cache.removeAll()
        #expect(cache.cached("al-2") == nil)

        // A cover that won't load is not cached as "no palette", so it's tried again.
        let none = await cache.palette(for: "al-4") { nil }
        #expect(none == nil)
        let later = await cache.palette(for: "al-4") { red }
        #expect(later != nil)

        // Bounded: the oldest goes first.
        let small = ArtPaletteCache(limit: 2)
        for id in ["x", "y", "z"] { _ = await small.palette(for: id) { red } }
        #expect(small.cached("x") == nil)
        #expect(small.cached("y") != nil && small.cached("z") != nil)
    }

    /// A 32 × 32 opaque image of one colour.
    static func image(_ hex: UInt32) -> UIImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32), format: format).image { ctx in
            UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255, alpha: 1).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        }
    }

    // MARK: Type

    @Test func immersiveFontsResolveOnThisOS() {
        // The faces Immersive asks for are system fonts on iOS 27: nothing bundled (R13 licensing call).
        let base = UIFont.systemFont(ofSize: 28, weight: .heavy).fontDescriptor
        let serif = UIFont(descriptor: base.withDesign(.serif)!, size: 28)
        // New York is the system serif: iOS names its family ".AppleSystemUIFontSerif" and its faces "NewYork…".
        let serifNames = serif.familyName + " " + serif.fontName
        #expect(serifNames.contains("Serif") || serifNames.contains("NewYork"), "\(serifNames)")
        #expect(serif.fontName != UIFont.systemFont(ofSize: 28, weight: .heavy).fontName)
        let mono = UIFont(descriptor: base.withDesign(.monospaced)!, size: 15)
        #expect(mono.familyName.localizedCaseInsensitiveContains("Mono"), "\(mono.familyName)")
        let compressed = UIFont.systemFont(ofSize: 22, weight: .heavy, width: .compressed)
        let standard = UIFont.systemFont(ofSize: 22, weight: .heavy)
        #expect(compressed.fontName != standard.fontName, "\(compressed.fontName)")
        let wide = NSAttributedString(string: "Popular", attributes: [.font: standard]).size().width
        let narrow = NSAttributedString(string: "Popular", attributes: [.font: compressed]).size().width
        #expect(narrow < wide * 0.9)

        // And the themes really use different type.
        let immersive = Theme(character: .immersive), signature = Theme(character: .signature), classic = Theme(character: .classic)
        for style in [Font.TextStyle.largeTitle, .title, .title2, .title3] {
            #expect(immersive.displayFont(style) != signature.displayFont(style), "\(style)")
        }
        #expect(immersive.numberFont() != signature.numberFont())
        #expect(immersive.capsuleFont != signature.capsuleFont)
        #expect(signature.capsuleFont == classic.capsuleFont)
        #expect(immersive.displayTracking(.largeTitle) < signature.displayTracking(.largeTitle))
        #expect(classic.displayTracking(.title) == 0)
        #expect(signature.displayTracking(.title) == -0.4)
    }

    // MARK: Layout

    /// Immersive's larger title still fits the smallest phone (375 × 667) without scrolling, art colours applied.
    @Test func nowPlayingFitsTheSmallestPhoneInImmersive() async throws {
        let name = "immersive-small-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let model = AppModel(store: SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.tests.\(UUID().uuidString)")),
                             matchIndexDirectory: nil, dataDirectory: nil, engine: FakeEngine(), defaults: defaults,
                             systemNowPlaying: false, notifications: false)
        model.player.play([
            Song(id: "s1", title: "North by Northwest, the long way round", artist: "The Midnight Cartographers",
                 album: "Atlas of Small Hours", duration: 200),
            Song(id: "s2", title: "Compass Rose", artist: "The Midnight Cartographers", album: "Atlas of Small Hours", duration: 180),
        ], startAt: 0)
        let art = ArtPalette(dominant: PaletteColor(hex: 0x1B2A49), accent: PaletteColor(hex: 0xF39C12))
        let theme = Theme(character: .immersive, accent: .sheen, art: art)

        let frames = NowPlayingSmallPhoneTests.Frames()
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 375, height: 667)
        defer { window.isHidden = true }
        let view = NowPlayingView().environment(model).magpieTheme(theme)
            .environment(\.nowPlayingFrameProbe) { key, frame in frames.byPart[key] = frame }
        let host = UIHostingController(rootView: view)
        window.rootViewController = host
        window.isHidden = false
        for _ in 0..<10 {
            try await Task.sleep(for: .milliseconds(100))
            host.view.layoutIfNeeded()
        }
        var previous: CGRect?
        for key in ["top", "art", "meta", "scrubber", "transport", "bottom"] {
            let frame = try #require(frames.byPart[key], "\(key) never laid out")
            #expect(window.bounds.contains(frame), "\(key) at \(frame) is off the 375 × 667 screen")
            if let previous { #expect(frame.minY >= previous.maxY - 0.5, "\(key) overlaps") }
            previous = frame
        }
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        #expect(image.size == CGSize(width: 375, height: 667))
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("immersive-now-playing-375x667.png")
        try image.pngData()?.write(to: out)
        print("R13 immersive render: \(out.path)")
    }
}
