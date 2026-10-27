import XCTest
@testable import Magpie

final class AppSmokeTests: XCTestCase {
    @MainActor func testCarPlaySceneDelegateExists() {
        _ = CarPlaySceneDelegate()
    }
}
