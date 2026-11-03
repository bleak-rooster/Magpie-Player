import CarPlay
import Foundation
import MagpieCore
import Testing
@testable import CarPlayUI
@testable import Magpie

/// Z3 review I1: signing out with Discover as the car's third tab. Sign-out disconnects Aurral, so the tab falls back to
/// Playlists in the same turn; the car must stay on the signed-out screen, never get its tabs back from the layout watch.
extension DiscoverAppTests {
    @Test func signingOutWithDiscoverAsTheCarsTabKeepsTheSignedOutScreen() async throws {
        let model = try await signedIn()
        model.updatePreferences { $0.carPlay.thirdTab = .discover }
        let car = FakeCarInterface()
        let controller = CarPlayController(interfaceController: car, library: CarPlayLibraryAdapter(model: model),
                                           player: model.player)
        defer { controller.disconnect() }
        controller.setAvailability(.ready(account: "one"))
        #expect(car.tabs?.templates.map { ($0 as? CPListTemplate)?.tabTitle } == ["Home", "Library", "Discover", "Search"])

        model.signOut()
        // The scene delegate's own watch sees the sign-out first.
        controller.setAvailability(CarPlaySceneDelegate.availability(model))
        try await Task.sleep(for: .milliseconds(400))
        #expect(car.tabs == nil, "the tabs never come back while signed out")
        #expect(FakeCarInterface.texts(car.topList) == ["Not set up on this iPhone yet"])
    }
}
