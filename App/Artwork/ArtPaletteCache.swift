import CoreGraphics
import DesignSystem
import UIKit

/// R13: Immersive's colours per cover, worked out on the phone from the cover image and kept in memory only, keyed by
/// cover id (no disk, no network of its own). Bounded; cleared with the artwork cache on sign-in and sign-out, and per
/// cover on "Reload artwork".
@MainActor
final class ArtPaletteCache {
    static let shared = ArtPaletteCache()
    private let limit: Int
    private var palettes: [String: ArtPalette] = [:]
    /// Oldest first, for eviction.
    private var order: [String] = []
    private var inFlight: [String: Task<ArtPalette?, Never>] = [:]
    /// Bumped by `removeAll()`, so a palette started for the previous account isn't kept.
    private var generation = 0

    init(limit: Int = 300) { self.limit = max(1, limit) }

    func cached(_ coverArtId: String) -> ArtPalette? { palettes[coverArtId] }

    /// The cover's palette, from memory or worked out from `image()`. A cover that doesn't load isn't remembered.
    func palette(for coverArtId: String, image: @escaping @MainActor () async -> UIImage?) async -> ArtPalette? {
        if let hit = palettes[coverArtId] { return hit }
        if let task = inFlight[coverArtId] { return await task.value }
        let started = generation
        let task = Task<ArtPalette?, Never> {
            guard let cgImage = await image()?.cgImage else { return nil }
            return await Task.detached(priority: .utility) { Self.extract(from: cgImage) }.value
        }
        inFlight[coverArtId] = task
        let palette = await task.value
        guard generation == started else { return nil }
        inFlight[coverArtId] = nil
        if let palette { store(palette, for: coverArtId) }
        return palette
    }

    func remove(_ coverArtId: String) {
        palettes[coverArtId] = nil
        order.removeAll { $0 == coverArtId }
    }

    func removeAll() {
        palettes = [:]
        order = []
        inFlight.values.forEach { $0.cancel() }
        inFlight = [:]
        generation += 1
    }

    private func store(_ palette: ArtPalette, for coverArtId: String) {
        if palettes[coverArtId] == nil { order.append(coverArtId) }
        palettes[coverArtId] = palette
        while order.count > limit { palettes[order.removeFirst()] = nil }
    }

    /// Side of the bitmap the palette is counted on: enough for the colours, cheap to count.
    nonisolated static let sampleSide = 24

    /// The cover drawn small into sRGB RGBA8, then counted (`ArtPalette.extract`).
    nonisolated static func extract(from image: CGImage) -> ArtPalette? {
        let side = sampleSide
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let ctx = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        return drawn ? ArtPalette.extract(rgba: pixels, width: side, height: side) : nil
    }
}
