import DesignSystem
import MagpieCore
import Requests
import SwiftUI

/// R18 + R20: Keep, asked for outside the Finds row's own button: a find's menus ("Keep") and an Only in your Finds
/// artist page ("Keep <artist>"). Each screen that can ask attaches `.findsKeepFlow(host:)`; the menu item names the
/// same host, so the screen on top runs it. Every find is kept through the same `AppModel.keep` (the runner proves it
/// on fresh state); when one moved into the library, "Kept. Add more from <artist>?" follows (the Add sheet, or one
/// confirmation with Add with my defaults on). Otherwise Keep says how it went.
private struct FindsKeepFlowModifier: ViewModifier {
    @Environment(AppModel.self) private var model
    let host: String
    @State private var addRequest: AddFlowRequest?
    @State private var message: String?

    func body(content: Content) -> some View {
        content
            .onChange(of: model.newMusic.keeping, initial: true) {
                guard let asked = model.newMusic.keeping, asked.host == host else { return }
                model.newMusic.keeping = nil
                Task { await run(asked) }
            }
            .addFlow($addRequest) { outcome in message = outcome.message }
            .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK", role: .cancel) {}
            }
    }

    private func run(_ asked: KeepFlowRequest) async {
        let ids = model.keepRequests(songIds: asked.songIds)
        guard !ids.isEmpty else {
            message = KeepCopy.unavailable
            return
        }
        model.newMusic.keepsRunning.formUnion(ids)
        defer { model.newMusic.keepsRunning.subtract(ids) }
        var moved: (RequestID, String)?
        var said: String?
        for id in ids {
            let reply = await model.keep(id)
            if reply.bringsInMore, moved == nil { moved = (id, reply.message) } else if said == nil { said = reply.message }
        }
        if let (id, kept) = moved {
            addRequest = model.afterKeepRequest(id, artist: asked.artist, kept: kept)
        } else {
            message = said ?? KeepCopy.unavailable
        }
    }
}

extension View {
    /// Runs the Keeps a menu or page on this screen asks for (`host` names this screen).
    func findsKeepFlow(host: String) -> some View { modifier(FindsKeepFlowModifier(host: host)) }
}

/// The "Keep" item for a find's menus (R18, R20: a find's menus say Keep). Nothing when the song isn't a ready find
/// or a Keep is already running for it.
///
/// Hook for Now Playing's More menu (X2, R9): put `FindsLibraryMenuItem(songId: song.id, artist: song.artist)` first
/// in the menu (Keep and Not for me first for a find), and `.findsKeepFlow(host: FindsLibraryMenuItem.nowPlaying)` on
/// the Now Playing view. Any other menu passes the host its own screen attached.
struct FindsLibraryMenuItem: View {
    static let nowPlaying = "nowPlaying"

    @Environment(AppModel.self) private var model
    let songId: String
    var artist: String = ""
    var host: String = FindsLibraryMenuItem.nowPlaying

    var body: some View {
        if !model.keepRequests(songIds: [songId]).isEmpty {
            Button(NewMusicCopy.keep, systemImage: "checkmark.seal") {
                model.newMusic.keeping = KeepFlowRequest(host: host, songIds: [songId], artist: artist)
            }
            .accessibilityIdentifier("menu-keep")
        }
    }
}
