import DesignSystem
import MagpieCore
import Playback
import SwiftUI

/// The queue: what's playing, Shuffle and Repeat, Up Next (plays before the rest), then the rest
/// of what's queued. Edit turns on drag handles; swipe a row to remove it; Clear drops everything
/// after the current song.
struct QueueView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmClear = false
    private let themed = Themed()

    var body: some View {
        let player = model.player
        let queue = player.queue
        let rest = Array(queue.upcoming.dropFirst(queue.upNext.count))
        NavigationStack {
            List {
                if let current = queue.current?.song {
                    Section {
                        Artwork(current.coverArtId, side: 48) { SongRow(song: current, state: .library, artwork: $0) }
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                            .moveDisabled(true)
                            .deleteDisabled(true)
                    } header: { header("Now playing") }
                    Section { modes(player) }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                Section {
                    if queue.upNext.isEmpty {
                        Text("Songs you add with Play Next land here, ahead of the rest.")
                            .font(.footnote).foregroundStyle(themed.palette.ink2Color)
                            .listRowBackground(Color.clear)
                            .moveDisabled(true)
                    }
                    ForEach(queue.upNext) { row($0) }
                        .onMove { from, to in move(from, to, in: queue.upNext, offset: 0) }
                        .onDelete { remove($0, from: queue.upNext) }
                } header: {
                    VStack(alignment: .leading, spacing: 2) {
                        header("Up Next")
                        Text("Plays before the rest of the queue").font(.footnote)
                            .foregroundStyle(themed.palette.ink2Color).textCase(nil)
                    }
                }
                if !rest.isEmpty {
                    Section {
                        ForEach(rest) { row($0) }
                            .onMove { from, to in move(from, to, in: rest, offset: queue.upNext.count) }
                            .onDelete { remove($0, from: rest) }
                    } header: { header("Playing next") }
                }
                if queue.current == nil {
                    ContentUnavailableView("Nothing in the queue", systemImage: "list.bullet")
                        .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .listRowSeparatorTint(themed.palette.sepColor)
            .navigationTitle("Queue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Clear") { confirmClear = true }
                        .disabled(queue.upcoming.isEmpty)
                        .accessibilityIdentifier("queue-clear")
                }
                ToolbarItem(placement: .topBarTrailing) { EditButton() }
            }
            .confirmationDialog("Clear everything after this song?", isPresented: $confirmClear,
                                titleVisibility: .visible) {
                Button("Clear", role: .destructive) { player.clearUpcoming() }
            } message: {
                Text("The song that's playing keeps playing.")
            }
            .magpieScreen()
        }
        .presentationDetents([.medium, .large])
    }

    private func header(_ title: String) -> some View {
        Text(title).magpieDisplay(.title3).foregroundStyle(themed.palette.inkColor)
            .textCase(nil).accessibilityAddTraits(.isHeader)
    }

    private func row(_ entry: QueueEntry) -> some View {
        Artwork(entry.song.coverArtId, side: 48) { SongRow(song: entry.song, state: .library, artwork: $0) }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .accessibilityAction(named: "Remove") { model.player.remove(id: entry.id) }
    }

    private func modes(_ player: Player) -> some View {
        HStack(spacing: Tokens.Spacing.m) {
            Button { player.setShuffled(!player.isShuffled) } label: {
                modeLabel("Shuffle", symbol: "shuffle", on: player.isShuffled)
            }
            .accessibilityValue(player.isShuffled ? "On" : "Off")
            .accessibilityAddTraits(player.isShuffled ? .isSelected : [])
            .accessibilityIdentifier("queue-shuffle")
            Button { player.repeatMode = player.repeatMode.next } label: {
                modeLabel(player.repeatMode == .one ? "Repeat one" : "Repeat",
                          symbol: player.repeatMode == .one ? "repeat.1" : "repeat", on: player.repeatMode != .off)
            }
            .accessibilityValue(Self.spoken(player.repeatMode))
            .accessibilityHint("Changes between off, all and one")
            .accessibilityAddTraits(player.repeatMode != .off ? .isSelected : [])
            .accessibilityIdentifier("queue-repeat")
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: player.repeatMode)
        .sensoryFeedback(.selection, trigger: player.isShuffled)
    }

    /// Text plus symbol, and a filled pill when on, so state doesn't rest on colour alone.
    private func modeLabel(_ title: String, symbol: String, on: Bool) -> some View {
        let p = themed.palette
        return Label(title, systemImage: symbol)
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: Tokens.minHitSize)
            .foregroundStyle(on ? p.onAccentColor : p.inkColor)
            .background(on ? p.accentColor : p.surfaceColor, in: Capsule())
    }

    static func spoken(_ mode: RepeatMode) -> String {
        switch mode {
        case .off: "Off"
        case .all: "All"
        case .one: "One song"
        }
    }

    /// `onMove` reports "insert before `to`" within a section; `Player.move` wants the final
    /// position within the whole upcoming list.
    private func move(_ from: IndexSet, _ to: Int, in entries: [QueueEntry], offset: Int) {
        guard let i = from.first, entries.indices.contains(i) else { return }
        model.player.move(id: entries[i].id, to: Self.finalPosition(from: i, insertBefore: to, offset: offset))
    }

    static func finalPosition(from i: Int, insertBefore to: Int, offset: Int) -> Int {
        offset + (to > i ? to - 1 : to)
    }

    private func remove(_ at: IndexSet, from entries: [QueueEntry]) {
        for i in at where entries.indices.contains(i) { model.player.remove(id: entries[i].id) }
    }
}
