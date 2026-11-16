import CarPlay
import Foundation
import Testing
@testable import CarPlayUI
@testable import Magpie

/// Round 28 crash hunt (R28X): going offline pops the car's server lists and puts Now Playing back on top in the pop's
/// completion. The car finishes a pop after its animation; if the car disconnected meanwhile, nothing may be pushed on
/// its torn-down interface controller.
extension CarPlayOfflineAppTests {
    @Test func car_popFinishingAfterDisconnectPushesNothing() async throws {
        let model = try await signedIn()
        await download(model, [Self.song("m-ref1")])
        let (car, controller) = await car(model)
        car.defersPopCompletions = true
        controller.open(.album(id: "al-server", title: "On the server"))
        model.play([Self.song("m-ref1"), Self.song("m-ref2")], startAt: 0)
        controller.showNowPlaying()
        #expect(car.templates.count == 3 && car.templates.last === nowPlaying)
        await goOffline(model)
        #expect(await eventually { car.pendingPops == 1 }, "the pop is under way")
        #expect(car.templates.count == 1)
        controller.disconnect()
        car.finishPops()
        #expect(car.templates.count == 1, "nothing pushed after the car disconnected")
    }

    /// Still connected, the late completion puts Now Playing back as before.
    @Test func car_popFinishingLatePutsNowPlayingBack() async throws {
        let model = try await signedIn()
        await download(model, [Self.song("m-ref1")])
        let (car, controller) = await car(model)
        defer { controller.disconnect() }
        car.defersPopCompletions = true
        controller.open(.album(id: "al-server", title: "On the server"))
        model.play([Self.song("m-ref1"), Self.song("m-ref2")], startAt: 0)
        controller.showNowPlaying()
        await goOffline(model)
        #expect(await eventually { car.pendingPops == 1 })
        car.finishPops()
        #expect(car.templates.count == 2 && car.templates.last === nowPlaying)
    }
}
