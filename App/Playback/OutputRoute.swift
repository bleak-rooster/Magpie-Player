import AVFoundation
import Foundation

/// Round 21 (owner, 2026-11-06, D167): where the sound plays, in words, to go with the output picker's colour (state is
/// never colour alone, D3). Nothing for the phone itself; for anything else (an AirPlay speaker, Bluetooth headphones,
/// the car) the output's own name and a symbol. Read from the audio session's current route.
enum OutputRoute {
    struct Output: Equatable {
        var name: String
        var symbol: String
    }

    /// The route's first output that isn't the phone's own speaker or earpiece; nil when the phone plays it.
    static func describe(_ outputs: [(type: AVAudioSession.Port, name: String)]) -> Output? {
        guard let first = outputs.first(where: { ![.builtInSpeaker, .builtInReceiver].contains($0.type) }) else { return nil }
        let name = first.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        return Output(name: name, symbol: symbol(for: first.type))
    }

    /// The output of the shared session's current route.
    static func current() -> Output? {
        describe(AVAudioSession.sharedInstance().currentRoute.outputs.map { ($0.portType, $0.portName) })
    }

    /// What VoiceOver says the picker is set to: the output's name, or "This iPhone" (this device's own model name).
    static func spoken(_ output: Output?, device: String) -> String {
        output?.name ?? "This \(device)"
    }

    private static func symbol(for type: AVAudioSession.Port) -> String {
        switch type {
        case .airPlay: "airplayaudio"
        case .carAudio: "car"
        case .headphones, .bluetoothA2DP, .bluetoothHFP, .bluetoothLE: "headphones"
        default: "hifispeaker"
        }
    }
}
