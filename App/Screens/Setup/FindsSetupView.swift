import LidarrKit
import NavidromeKit
import SwiftUI

/// Settings › Finds (Task 6.1): "Use a Finds folder" (off by default), the owner confirms which Lidarr root
/// folder is the Finds folder (G2, never guessed from a name), picks the Navidrome library that is the same
/// folder, and says how the paths match when they differ (B6). Nothing here writes to Lidarr (G5).
struct FindsSetupView: View {
    @Environment(AppModel.self) private var model
    @State private var pendingRoot: String?
    @State private var rootError: String?
    @State private var libraries: [NavidromeLibrary]?
    @State private var librariesError: String?
    @State private var libraryError: String?
    @State private var mappingFor: NavidromeLibrary?
    @State private var lidarrPrefix = ""
    @State private var navidromePrefix = ""

    private var setup: FindsSetup? { model.findsSetup }

    var body: some View {
        Form {
            Section {
                Toggle("Use a Finds folder", isOn: Binding(
                    get: { setup?.useFindsFolder ?? false }, set: { model.setUseFindsFolder($0) }))
                    .accessibilityIdentifier("finds-toggle")
                    .disabled(setup == nil)
            } footer: {
                Text("Finds are songs you're trying out. They live in a folder of their own, so you can keep them or let them go. "
                     + (setup?.useFindsFolder == true ? (setup?.isComplete == true ? FindsCopy.done : FindsCopy.notFinished)
                                                     : FindsCopy.off))
                    .accessibilityIdentifier("finds-status")
            }
            if setup?.useFindsFolder == true {
                rootSection
                if setup?.findsRoot != nil { librarySection }
                if mappingFor != nil { mappingSection }
                if model.findsNeedsRecycleBinWarning {
                    Section {
                        Label(FindsCopy.recycleBinOff, systemImage: "exclamationmark.triangle")
                            .accessibilityIdentifier("finds-recycle-warning")
                    }
                }
            }
        }
        .navigationTitle("Finds")
        .confirmationDialog(pendingRoot.map(FindsCopy.confirmTitle) ?? "", isPresented: Binding(
            get: { pendingRoot != nil }, set: { if !$0 { pendingRoot = nil } }), titleVisibility: .visible) {
            Button("Use for Finds") {
                if let root = pendingRoot { confirm(root) }
                pendingRoot = nil
            }
            .accessibilityIdentifier("finds-confirm")
            Button("Cancel", role: .cancel) { pendingRoot = nil }
        } message: {
            Text(FindsCopy.confirmMessage)
        }
        .task(id: setup?.findsRoot) { if setup?.findsRoot != nil, libraries == nil { await loadLibraries() } }
    }

    // MARK: - Finds folder (Lidarr root)

    @ViewBuilder private var rootSection: some View {
        let roots = model.lidarrStatus?.roots.map(\.path) ?? []
        Section {
            if roots.isEmpty {
                Text("No root folder in Lidarr").foregroundStyle(.secondary)
            }
            ForEach(roots, id: \.self) { root in
                let problem = model.findsRootProblem(root)
                let chosen = setup?.findsRoot == root
                Button {
                    rootError = nil
                    pendingRoot = root
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(root)
                            if let problem, !chosen {
                                Text(problem.message).font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if chosen { Image(systemName: "checkmark").accessibilityLabel("Finds folder") }
                    }
                }
                .foregroundStyle(.primary)
                .disabled(problem != nil || chosen)
                .accessibilityIdentifier("finds-root-\(root)")
            }
            if let rootError { Text(rootError).font(.footnote) }
        } header: {
            Text("Finds folder")
        } footer: {
            Text("Choose the Lidarr root folder for finds. Magpie never picks it for you.")
        }
    }

    private func confirm(_ root: String) {
        do {
            try model.confirmFindsRoot(root)
            mappingFor = nil
            libraryError = nil
        } catch {
            rootError = error.message
        }
    }

    // MARK: - Library (Navidrome)

    @ViewBuilder private var librarySection: some View {
        Section {
            if let libraries {
                ForEach(libraries) { library in
                    Button { choose(library, mapping: nil) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(library.name.isEmpty ? library.path : library.name)
                                Text(library.path).font(.footnote).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if setup?.library?.id == library.id {
                                Image(systemName: "checkmark").accessibilityLabel("Finds library")
                            }
                        }
                    }
                    .foregroundStyle(.primary)
                    .accessibilityIdentifier("finds-library-\(library.id)")
                }
                if libraries.isEmpty { Text("No libraries found").foregroundStyle(.secondary) }
            } else if let librariesError {
                Text(librariesError).font(.footnote)
                Button("Try again") { Task { await loadLibraries() } }
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
            if let libraryError { Text(libraryError).font(.footnote).accessibilityIdentifier("finds-library-error") }
        } header: {
            Text("In Navidrome")
        } footer: {
            Text("Choose the Navidrome library that is this same folder, so finds show up when they arrive.")
        }
    }

    private func loadLibraries() async {
        librariesError = nil
        do {
            libraries = try await model.navidromeLibraries()
        } catch NavidromeError.http(status: 403) {
            librariesError = FindsCopy.librariesForbidden
        } catch {
            librariesError = FindsCopy.librariesFailed
        }
    }

    private func choose(_ library: NavidromeLibrary, mapping: PathMapping?) {
        do {
            try model.chooseFindsLibrary(library, among: libraries ?? [], mapping: mapping)
            libraryError = nil
            mappingFor = nil
        } catch {
            libraryError = error.message
            if error == .pathsDiffer || error == .mappingMismatch, mappingFor?.id != library.id {
                mappingFor = library
                lidarrPrefix = setup?.findsRoot ?? ""
                navidromePrefix = library.path
            }
        }
    }

    // MARK: - Path mapping (B6)

    @ViewBuilder private var mappingSection: some View {
        Section {
            LabeledContent("Lidarr sees") {
                TextField("/data/music", text: $lidarrPrefix).multilineTextAlignment(.trailing)
                    .accessibilityIdentifier("finds-map-lidarr")
            }
            LabeledContent("Navidrome sees") {
                TextField("/music", text: $navidromePrefix).multilineTextAlignment(.trailing)
                    .accessibilityIdentifier("finds-map-navidrome")
            }
            Button("Use these paths") {
                if let library = mappingFor {
                    choose(library, mapping: PathMapping(lidarrPrefix: lidarrPrefix, navidromePrefix: navidromePrefix))
                }
            }
            .accessibilityIdentifier("finds-map-save")
        } header: {
            Text("Paths")
        } footer: {
            Text("Lidarr and Navidrome can see the same folder under different paths. Give the start of each path that means the same place.")
        }
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
    }
}
