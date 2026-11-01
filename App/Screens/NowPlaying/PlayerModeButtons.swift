import DesignSystem
import MagpieCore
import Playback
import SwiftUI

/// R6: shuffle and repeat. The same calls as the lock screen's commands and CarPlay's buttons
/// (`NowPlayingBridge`), so the system's current types (CarPlay draws Repeat One from them) follow at once.
@MainActor
enum PlayerModeControls {
    static func toggleShuffle(_ player: Player) {
        NowPlayingBridge.applyShuffle(player.isShuffled ? .off : .items, to: player)
    }

    /// Off → All → One → Off.
    static func cycleRepeat(_ player: Player) {
        NowPlayingBridge.applyRepeat(NowPlayingBridge.repeatType(player.repeatMode.next), to: player)
    }

    static func shuffleValue(_ player: Player) -> String { player.isShuffled ? "On" : "Off" }

    static func repeatSymbol(_ mode: RepeatMode) -> String { mode == .one ? "repeat.1" : "repeat" }

    /// VoiceOver reads "Repeat, one".
    static func repeatValue(_ mode: RepeatMode) -> String {
        switch mode {
        case .off: "Off"
        case .all: "All"
        case .one: "One"
        }
    }
}

/// Now Playing's shuffle or repeat button, flanking the transport (R6): the symbol in the accent on a surface disc
/// when on, so the state doesn't rest on colour alone (D3: the disc and, for One, the symbol).
struct PlayerModeButton: View {
    enum Kind { case shuffle, repeatMode }

    @Environment(AppModel.self) private var model
    let kind: Kind
    private let themed = Themed()

    var body: some View {
        let player = model.player
        let p = themed.palette
        let on = kind == .shuffle ? player.isShuffled : player.repeatMode != .off
        Button {
            kind == .shuffle ? PlayerModeControls.toggleShuffle(player) : PlayerModeControls.cycleRepeat(player)
        } label: {
            Image(systemName: kind == .shuffle ? "shuffle" : PlayerModeControls.repeatSymbol(player.repeatMode))
                .font(.title3.weight(.semibold))
                .foregroundStyle(on ? p.accentInkColor : p.ink2Color)
                .frame(width: Tokens.minHitSize, height: Tokens.minHitSize)
                .background(on ? p.solidSurfaceColor : .clear, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(kind == .shuffle ? "Shuffle" : "Repeat")
        .accessibilityValue(kind == .shuffle ? PlayerModeControls.shuffleValue(player)
                                             : PlayerModeControls.repeatValue(player.repeatMode))
        .accessibilityHint(kind == .repeatMode ? "Changes between off, all and one" : "")
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityIdentifier(kind == .shuffle ? "np-shuffle" : "np-repeat")
        .sensoryFeedback(.selection, trigger: kind == .shuffle ? "\(player.isShuffled)" : player.repeatMode.rawValue)
    }
}
