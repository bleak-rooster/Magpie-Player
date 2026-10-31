import DesignSystem
import NavidromeKit
import Requests
import SwiftUI

/// R18 + R20, Settings › New music: "Add with my defaults" (on by default) and "When you add an artist", the
/// choices every Add uses (on) or starts from (off). Saved on this iPhone.
struct NewMusicDefaultsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.newMusic
        Section {
            Toggle(NewMusicCopy.withMyDefaults, isOn: $settings.withMyDefaults)
                .accessibilityIdentifier("settings-add-with-my-defaults")
            NavigationLink {
                WhenYouAddView()
            } label: {
                LabeledContent(NewMusicCopy.whenYouAdd) {
                    Text(NewMusicCopy.what(AddWhat(settings.whenYouAdd)))
                }
            }
            .accessibilityIdentifier("settings-when-you-add")
        } header: {
            Text(NewMusicCopy.whenYouAdd)
        } footer: {
            Text(NewMusicCopy.withMyDefaultsFooter)
        }
    }
}

/// Settings › New music › When you add an artist: what to add (the whole-artist rows: "Just this album" needs an
/// album, so it's chosen in the Add sheet only), the kinds (Studio on by default; Official applied silently), the
/// quality and Follow new releases.
struct WhenYouAddView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.newMusic
        Form {
            Section(NewMusicCopy.whatHeader) {
                ForEach([AddWhat.albumsAndEPs, .albums, .everything]) { what in
                    let isOn = AddWhat(settings.whenYouAdd) == what
                    Button {
                        settings.whenYouAdd = what.applied(to: settings.whenYouAdd)
                    } label: {
                        HStack {
                            Text(NewMusicCopy.what(what)).foregroundStyle(.primary)
                            Spacer()
                            if isOn { Image(systemName: "checkmark").accessibilityHidden(true) }
                        }
                        .frame(minHeight: Tokens.minHitSize)
                        .contentShape(Rectangle())
                    }
                    .accessibilityAddTraits(isOn ? .isSelected : [])
                    .accessibilityIdentifier("when-what-\(what.rawValue)")
                }
            }
            Section(NewMusicCopy.kindsHeader) {
                Toggle(NewMusicCopy.studio, isOn: $settings.whenYouAdd.types.studio).accessibilityIdentifier("when-studio")
                Toggle(NewMusicCopy.live, isOn: $settings.whenYouAdd.types.live).accessibilityIdentifier("when-live")
                Toggle(NewMusicCopy.soundtracks, isOn: $settings.whenYouAdd.types.soundtrack)
                    .accessibilityIdentifier("when-soundtracks")
            }
            Section {
                Picker(NewMusicCopy.qualityHeader, selection: $settings.whenYouAdd.quality) {
                    ForEach(DownloadChoices.Quality.allCases, id: \.self) { Text(NewMusicCopy.quality($0)).tag($0) }
                }
                .accessibilityIdentifier("when-quality")
            } footer: {
                Text(NewMusicCopy.qualityFooter)
            }
            Section {
                Toggle(NewMusicCopy.follow, isOn: $settings.whenYouAdd.follow).accessibilityIdentifier("when-follow")
            } footer: {
                Text(NewMusicCopy.followNote)
            }
        }
        .navigationTitle(NewMusicCopy.whenYouAdd)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// R18, Settings › Finds: the main library (your main collection in Navidrome, picked from the server's libraries,
/// automatically when only one other library exists) shown with the main folder (Lidarr's "New music goes to"), so
/// the pair is explicit. Used for the scan after a Keep and for "Only in your Finds".
struct MainLibrarySection: View {
    @Environment(AppModel.self) private var model
    let libraries: [NavidromeLibrary]

    var body: some View {
        let choices = AppModel.mainLibraryChoices(libraries, findsLibrary: model.findsSetup?.library)
        let main = model.findsSetup?.mainLibrary
        Section {
            if choices.count > 1 {
                Picker(NewMusicCopy.mainLibrary, selection: Binding(
                    get: { main?.id ?? -1 },
                    set: { id in if let library = choices.first(where: { $0.id == id }) { model.chooseMainLibrary(library) } })) {
                    if main == nil { Text("Choose\u{2026}").tag(-1) }
                    ForEach(choices) { Text($0.name.isEmpty ? $0.path : $0.name).tag($0.id) }
                }
                .accessibilityIdentifier("finds-main-library")
            } else {
                LabeledContent(NewMusicCopy.mainLibrary, value: main.map { $0.name.isEmpty ? $0.path : $0.name } ?? "None")
                    .accessibilityIdentifier("finds-main-library")
            }
            LabeledContent(NewMusicCopy.mainFolder, value: model.lidarrSetup?.rootFolderPath ?? "Not chosen yet")
                .accessibilityIdentifier("finds-main-folder")
        } header: {
            Text("Your library")
        } footer: {
            Text(NewMusicCopy.mainLibraryFooter)
        }
        .onAppear { model.reconcileMainLibrary(libraries) }
        .onChange(of: libraries) { model.reconcileMainLibrary(libraries) }
    }
}
