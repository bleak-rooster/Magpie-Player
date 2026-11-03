import NavidromeKit
import SwiftUI

/// Settings › Accounts & Servers › Navidrome (round 13 item 14; was Account & Server): the server's addresses (marked
/// "Not encrypted" when plain http outside home, T2), who is signed in, Local Network access (T3), the libraries and
/// what each is for (Y3: which ones Home, Library and Search show), the main library (R18; moved here from Finds
/// set-up), and Sign out.
struct AccountSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var askingLocalNetwork = false
    @State private var confirmsSignOut = false
    @State private var libraries: [NavidromeLibrary]?
    /// Closes the Settings sheet (this page's own `dismiss` would only go back).
    let dismissSettings: () -> Void

    var body: some View {
        Form {
            Section {
                if let session = model.session {
                    ForEach(Array(session.endpoint.bases.enumerated()), id: \.offset) { index, base in
                        LabeledContent(index == 0 ? "Address" : "Also tries") {
                            AddressValue(value: base.absoluteString, base: base)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    LabeledContent("Signed in as", value: session.username)
                    localNetworkRows
                }
            }
            if let libraries, libraries.count > 1 {
                librariesSection(libraries)
                if model.findsSetup != nil {
                    MainLibrarySection(libraries: libraries)   // R18 (the choice needs Lidarr's set-up)
                }
            }
            if model.session != nil {
                Section {
                    Button("Sign out", role: .destructive) { confirmsSignOut = true }
                        .accessibilityIdentifier("settings-sign-out")
                }
            }
        }
        .navigationTitle(SettingsCopy.navidrome)
        .task { if !model.isOffline, libraries == nil { libraries = try? await model.navidromeLibraries() } }
        .navigationBarTitleDisplayMode(.inline)
        // Signing out erases this account's downloads (Task 12), so it asks first (T21b fix round).
        .confirmationDialog(AccountCopy.signOutTitle, isPresented: $confirmsSignOut, titleVisibility: .visible) {
            Button(AccountCopy.signOutConfirm, role: .destructive) {
                dismissSettings()
                model.signOut()
            }
            .accessibilityIdentifier("settings-sign-out-confirm")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(AccountCopy.signOutMessage)
        }
    }

    /// Y3: each library and what Magpie does with it (Home, Library and Search show the listed ones).
    private func librariesSection(_ libraries: [NavidromeLibrary]) -> some View {
        Section {
            ForEach(libraries) { library in
                LabeledContent(library.name.isEmpty ? library.path : library.name,
                               value: AccountCopy.libraryRole(library.id, main: model.mainLibraryId,
                                                              listed: model.listedLibraryIds, finds: model.findsLibraryId,
                                                              discover: model.discoverLibraryIds))
                    .accessibilityIdentifier("settings-library-\(library.id)")
            }
        } header: {
            Text("Libraries")
        } footer: {
            Text(AccountCopy.librariesFooter)
        }
    }

    /// T3: Connect's Local Network message and buttons: the message and Open Settings while it is off, and the
    /// button to ask again until it is known to be on.
    @ViewBuilder private var localNetworkRows: some View {
        if model.localNetwork.state == .denied {
            Label(ConnectDiagnosis.localNetworkDenied.message, systemImage: "network.slash")
                .accessibilityIdentifier("settings-local-network-denied")
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
            .accessibilityIdentifier("settings-open-settings")
        }
        if model.localNetwork.state != .granted {
            Button {
                Task {
                    askingLocalNetwork = true
                    defer { askingLocalNetwork = false }
                    await model.localNetwork.request()
                }
            } label: {
                HStack {
                    Label("Allow local network access", systemImage: "network")
                    if askingLocalNetwork { Spacer(); ProgressView() }
                }
            }
            .disabled(askingLocalNetwork)
            .accessibilityIdentifier("settings-allow-local-network")
        }
    }
}

enum AccountCopy {
    static let librariesFooter = "Home, Library and Search show your music. Finds and Discover have their own places."

    /// What a library is for: the main one, another one shown, Finds', Discover's, or not shown. With nothing listed
    /// (`listed` nil) every library is shown.
    static func libraryRole(_ id: Int, main: Int?, listed: [Int]?, finds: Int?, discover: Set<Int>) -> String {
        if id == finds { return "Finds" }
        if discover.contains(id) { return DiscoverCopy.title }
        if id == main { return NewMusicCopy.mainLibrary }
        guard let listed else { return "Shown" }
        return listed.contains(id) ? "Shown" : "Not shown"
    }

    static let signOutTitle = "Sign out?"
    static let signOutMessage = "Songs downloaded to this phone will be removed."
    static let signOutConfirm = "Sign Out"
}
