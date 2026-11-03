import SwiftUI

/// Round 13 Z2 (plan item 13): Home's and Library's layout editors (the same pages as Settings › Home & Library) as a
/// sheet with Done. Each switch and move is saved as it is made, so the page behind follows at once.
struct LayoutEditorSheet<Editor: View>: View {
    @Environment(\.dismiss) private var dismiss
    let doneIdentifier: String
    @ViewBuilder let editor: () -> Editor

    var body: some View {
        NavigationStack {
            editor()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }.accessibilityIdentifier(doneIdentifier)
                    }
                }
                .magpieScreen()   // Task 21: the app's theme in the sheet too
        }
    }
}

/// The toolbar button that opens a layout editor: the symbol of Home's "Edit Home", named for VoiceOver.
struct LayoutEditButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "slider.horizontal.3")
        }
        .accessibilityLabel(title)
    }
}
