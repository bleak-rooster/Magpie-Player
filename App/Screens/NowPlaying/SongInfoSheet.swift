import DesignSystem
import MagpieCore
import NavidromeKit
import SwiftUI

/// Now Playing › More › Song info (round 11 R9): the song's facts, what is playing, and the original file. Never the
/// file's path. Offline (or when the server doesn't answer) only what the phone knows is shown.
struct SongInfo: Equatable {
    struct Row: Equatable, Identifiable {
        let label: String
        let value: String
        var id: String { label }
    }

    /// Where the sound comes from: a file on the phone in `quality`, or a stream in `quality`.
    enum Source: Equatable {
        case onPhone(StreamQuality)
        case stream(StreamQuality)
    }

    let rows: [Row]

    init(song: Song, details: SongDetails?, source: Source) {
        let suffix = details?.suffix ?? song.suffix
        var rows: [Row] = [Row(label: "Title", value: song.title)]
        func add(_ label: String, _ value: String?) {
            if let value, !value.isEmpty { rows.append(Row(label: label, value: value)) }
        }
        add("Artist", song.artist)
        add("Album", song.album)
        add("Year", details?.year.map(String.init))
        add("Genre", details?.song.genre ?? song.genre)
        add("Duration", song.duration > 0 ? DurationText.clock(song.duration) : nil)
        add("Playing", Self.playing(source, originalSuffix: suffix))
        add("Original format", Self.original(suffix: suffix, bitRate: details?.bitRate ?? song.bitRate,
                                              samplingRate: details?.samplingRate, bitDepth: details?.bitDepth))
        add("File size", details?.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) })
        add("Plays", details?.playCount.map(String.init))
        self.rows = rows
    }

    /// "AAC 160 kbps, streaming"; "Original (FLAC), on this iPhone".
    static func playing(_ source: Source, originalSuffix: String?) -> String {
        let quality: StreamQuality
        let place: String
        switch source {
        case .onPhone(let q): quality = q; place = "on this iPhone"
        case .stream(let q): quality = q; place = "streaming"
        }
        let what = quality == .original ? "Original" + (originalSuffix.map { " (\($0.uppercased()))" } ?? "")
                                        : quality.shortTitle
        return "\(what), \(place)"
    }

    /// "FLAC · 1,011 kbps · 44.1 kHz · 16-bit".
    static func original(suffix: String?, bitRate: Int?, samplingRate: Int?, bitDepth: Int?) -> String? {
        var parts: [String] = []
        if let suffix, !suffix.isEmpty { parts.append(suffix.uppercased()) }
        if let bitRate, bitRate > 0 { parts.append("\(bitRate.formatted()) kbps") }
        if let samplingRate, samplingRate > 0 {
            parts.append("\((Double(samplingRate) / 1000).formatted(.number.precision(.fractionLength(0...1)))) kHz")
        }
        if let bitDepth, bitDepth > 0 { parts.append("\(bitDepth)-bit") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

extension AppModel {
    /// Song info for `song`: the server's facts when it answers, and where the sound comes from now.
    func songInfo(_ song: Song) async -> SongInfo {
        let details = isOffline ? nil : try? await request { try await $0.songDetails(id: song.id) }
        let local = await downloads?.store.entry(songId: song.id)
        let source: SongInfo.Source
        if let local {
            source = .onPhone(local.quality)
        } else if player.lastFallbackSongId == song.id {
            source = .stream(.original)   // the transcode failed, so the original plays (Task 7)
        } else {
            source = .stream(currentStreamQuality)
        }
        return SongInfo(song: song, details: details, source: source)
    }
}

struct SongInfoSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let song: Song
    @State private var info: SongInfo?

    var body: some View {
        NavigationStack {
            List {
                ForEach((info ?? SongInfo(song: song, details: nil, source: .stream(model.currentStreamQuality))).rows) { row in
                    LabeledContent(row.label, value: row.value)
                        .accessibilityIdentifier("song-info-\(row.label)")
                }
            }
            .navigationTitle("Song info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .task(id: song.id) { info = await model.songInfo(song) }
        .presentationDetents([.medium, .large])
    }
}
