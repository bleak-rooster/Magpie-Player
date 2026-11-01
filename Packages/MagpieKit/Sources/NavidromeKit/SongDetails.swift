import Foundation
import MagpieCore

/// What the server says about one song's file, for Now Playing's Song info (round 11 R9). Never the file's path.
public struct SongDetails: Sendable, Hashable {
    public var song: Song
    public var year: Int?
    /// The original file's size in bytes.
    public var size: Int64?
    public var playCount: Int?
    /// The original file: its suffix ("flac"), bit rate (kbps), sample rate (Hz) and bit depth.
    public var suffix: String?
    public var bitRate: Int?
    public var samplingRate: Int?
    public var bitDepth: Int?

    public init(song: Song, year: Int? = nil, size: Int64? = nil, playCount: Int? = nil, suffix: String? = nil,
                bitRate: Int? = nil, samplingRate: Int? = nil, bitDepth: Int? = nil) {
        self.song = song; self.year = year; self.size = size; self.playCount = playCount; self.suffix = suffix
        self.bitRate = bitRate; self.samplingRate = samplingRate; self.bitDepth = bitDepth
    }

    init(_ d: SubsonicSong) {
        self.init(song: Mapping.song(d), year: d.year.flatMap { $0 > 0 ? $0 : nil },
                  size: d.size.flatMap { $0 > 0 ? Int64($0) : nil }, playCount: d.playCount.map { max($0, 0) },
                  suffix: d.suffix, bitRate: d.bitRate.flatMap { $0 > 0 ? $0 : nil },
                  samplingRate: d.samplingRate.flatMap { $0 > 0 ? $0 : nil }, bitDepth: d.bitDepth.flatMap { $0 > 0 ? $0 : nil })
    }
}
