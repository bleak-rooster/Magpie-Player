import SwiftUI

@main
struct MagpieApp: App {
    var body: some Scene {
        WindowGroup {
            ConnectPlaceholderView()
        }
    }
}

struct ConnectPlaceholderView: View {
    var body: some View {
        NavigationStack {
            Text("Connect your music")
                .font(.title)
                .navigationTitle("Magpie")
        }
    }
}
