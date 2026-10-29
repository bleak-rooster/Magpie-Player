import DesignSystem
import SwiftUI

/// "You're offline", as text with its symbol (D3), on the screens offline mode changes (Task 14).
struct OfflineNotice: View {
    private let themed = Themed()

    var body: some View {
        Label(AppModel.offlineCopy, systemImage: "wifi.slash")
            .font(.subheadline)
            .foregroundStyle(themed.palette.ink2Color)
            .accessibilityIdentifier("offline-notice")
    }
}

enum OfflineCopy {
    /// A page offline whose music isn't on the phone (it was removed, or never downloaded).
    static let notOnPhone = "This isn't on this phone. It'll be here again when you're back online."
}
