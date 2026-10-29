import DesignSystem
import MagpieCore
import Search
import SwiftUI

/// "Move to group…" (spec §4, Task 19): every group not hidden, the genre's own ticked, then a new group by name. The
/// move is kept in Preferences.
struct MoveGenreSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let genre: String
    /// The groups the genre is in now (more than one for a multi-value genre).
    @State private var current: Set<String> = []
    @State private var newName = ""
    private let themed = Themed()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(model.genreGroupChoices, id: \.id) { group in
                        Button {
                            model.moveGenre(genre, toGroup: group.id)
                            dismiss()
                        } label: {
                            HStack {
                                Text(group.name).foregroundStyle(themed.palette.inkColor)
                                Spacer()
                                if current.contains(group.id) {
                                    Image(systemName: "checkmark").foregroundStyle(themed.palette.accentInkColor)
                                        .accessibilityHidden(true)
                                }
                            }
                            .frame(minHeight: Tokens.minHitSize)
                            .contentShape(Rectangle())
                        }
                        .accessibilityAddTraits(current.contains(group.id) ? .isSelected : [])
                        .accessibilityIdentifier("move-to-\(group.id)")
                    }
                }
                Section {
                    TextField("New group…", text: $newName)
                        .submitLabel(.done)
                        .onSubmit(createAndMove)
                        .accessibilityIdentifier("new-group-name")
                    Button("Move to new group", action: createAndMove)
                        .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.canCreateGroup)
                        .accessibilityIdentifier("move-to-new-group")
                } footer: {
                    if !model.canCreateGroup { Text("You have as many groups as Magpie keeps. Rename one instead.") }
                }
            }
            .navigationTitle("Move \(genre)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .magpieScreen()
        }
        .task {
            let sections = (try? await model.genreSectionsIncludingHidden()) ?? []
            current = Set(sections.filter { $0.genres.contains { $0.name == genre } }.map(\.group.id))
        }
    }

    private func createAndMove() {
        guard model.canCreateGroup, !newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        model.moveGenre(genre, toGroup: model.createGroup(named: newName))
        dismiss()
    }
}
