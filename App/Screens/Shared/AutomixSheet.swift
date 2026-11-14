import DesignSystem
import MagpieCore
import Search
import SwiftUI

/// Round 27 A (owner item 17, 2026-11-14: "You should be able to select the length of the automix and also select how
/// variable you want the selection."; owner Q5; D305): the Automix sheet, from Now Playing ⋯ (a song) or the library
/// artist page (an artist). Length and Variety remembered on the phone, the variety's one-line footer, the seed's note
/// (what it replaces), and Start Automix. Starting closes the sheet; the builder says how it went through the library's
/// notices.
///
/// Fix round 1 (design H3, M1, M2): segmented choices at ordinary sizes, inline lists at accessibility sizes (the sheet
/// then opens full height); Start Automix pinned at the bottom so it is always in reach; each choice read once by
/// VoiceOver (its label and value; the section headings are hidden from it), Variety's footer as its hint.
struct AutomixSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    let seed: AutomixSeed

    @State private var length: Automix.Length = .standard
    @State private var variety: Automix.Variety = .standard
    @State private var loaded = false
    private let themed = Themed()
    /// Accessibility sizes: inline lists, each row read on its own under its (spoken) heading and footer.
    private var large: Bool { typeSize.isAccessibilitySize }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(AutomixCopy.intro(seed)).font(.body).foregroundStyle(themed.palette.inkColor)
                        .accessibilityIdentifier("automix-intro")
                }
                Section {
                    choice(AutomixCopy.lengthLabel, selection: $length, options: Automix.Length.allCases,
                           title: AutomixCopy.length)
                        .accessibilityIdentifier("automix-length")
                } header: {
                    Text(AutomixCopy.lengthLabel).accessibilityHidden(!large)
                }
                Section {
                    choice(AutomixCopy.varietyLabel, selection: $variety, options: Automix.Variety.allCases,
                           title: AutomixCopy.variety)
                        .accessibilityHint(large ? "" : AutomixCopy.footer(variety))
                        .accessibilityIdentifier("automix-variety")
                } header: {
                    Text(AutomixCopy.varietyLabel).accessibilityHidden(!large)
                } footer: {
                    Text(AutomixCopy.footer(variety)).accessibilityHidden(!large)
                        .accessibilityIdentifier("automix-variety-footer")
                }
                Section {
                    Label(AutomixCopy.note(seed), systemImage: "text.line.first.and.arrowtriangle.forward")
                        .font(.footnote).foregroundStyle(themed.palette.ink2Color)
                        .accessibilityIdentifier("automix-note")
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    model.startAutomix(seed, length: length, variety: variety)
                    dismiss()
                } label: {
                    Label(AutomixCopy.start, systemImage: AutomixCopy.symbol)
                        .frame(maxWidth: .infinity, minHeight: Tokens.minHitSize)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal, Tokens.Spacing.margin)
                .padding(.vertical, Tokens.Spacing.s)
                .background(.bar)
                .accessibilityIdentifier("automix-start")
            }
            .navigationTitle(AutomixCopy.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .magpieScreen()
            .onAppear {
                guard !loaded else { return }
                loaded = true
                length = model.automixLength
                variety = model.automixVariety
            }
            .onChange(of: length) { if loaded { model.automixLength = length } }
            .onChange(of: variety) { if loaded { model.automixVariety = variety } }
        }
        .presentationDetents(large ? [.large] : [.medium, .large])
    }

    /// A choice: segmented at ordinary sizes (read as "<label>, <value>"), an inline list at accessibility sizes (D15).
    @ViewBuilder private func choice<Option: Hashable>(_ label: String, selection: Binding<Option>, options: [Option],
                                                       title: @escaping (Option) -> String) -> some View {
        let picker = Picker(label, selection: selection) {
            ForEach(options, id: \.self) { Text(title($0)).tag($0) }
        }
        if large {
            picker.pickerStyle(.inline).labelsHidden()
        } else {
            picker.pickerStyle(.segmented).frame(minHeight: Tokens.minHitSize)
                .accessibilityLabel(label)
                .accessibilityValue(title(selection.wrappedValue))
        }
    }
}
