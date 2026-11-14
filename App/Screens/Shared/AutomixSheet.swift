import DesignSystem
import MagpieCore
import Search
import SwiftUI

/// Round 27 A (owner item 17, 2026-11-14: "You should be able to select the length of the automix and also select how
/// variable you want the selection."; owner Q5; D305): the Automix sheet, from Now Playing ⋯ (a song) or the library
/// artist page (an artist). Length and Variety as segmented choices remembered on the phone, the variety's one-line
/// footer, the note that what's coming up is replaced, and Start Automix. Starting closes the sheet; the builder says
/// how it went through the library's notices.
struct AutomixSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let seed: AutomixSeed

    @State private var length: Automix.Length = .standard
    @State private var variety: Automix.Variety = .standard
    @State private var loaded = false
    private let themed = Themed()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(AutomixCopy.intro(seed)).font(.body).foregroundStyle(themed.palette.inkColor)
                        .accessibilityIdentifier("automix-intro")
                }
                Section {
                    Picker(AutomixCopy.lengthLabel, selection: $length) {
                        ForEach(Automix.Length.allCases, id: \.self) { Text(AutomixCopy.length($0)).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(minHeight: Tokens.minHitSize)
                    .accessibilityLabel(AutomixCopy.lengthLabel)
                    .accessibilityValue(AutomixCopy.length(length))
                    .accessibilityIdentifier("automix-length")
                } header: {
                    Text(AutomixCopy.lengthLabel)
                }
                Section {
                    Picker(AutomixCopy.varietyLabel, selection: $variety) {
                        ForEach(Automix.Variety.allCases, id: \.self) { Text(AutomixCopy.variety($0)).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(minHeight: Tokens.minHitSize)
                    .accessibilityLabel(AutomixCopy.varietyLabel)
                    .accessibilityValue(AutomixCopy.variety(variety))
                    .accessibilityIdentifier("automix-variety")
                } header: {
                    Text(AutomixCopy.varietyLabel)
                } footer: {
                    Text(AutomixCopy.footer(variety)).accessibilityIdentifier("automix-variety-footer")
                }
                Section {
                    Label(AutomixCopy.note, systemImage: "text.line.first.and.arrowtriangle.forward")
                        .font(.footnote).foregroundStyle(themed.palette.ink2Color)
                        .accessibilityIdentifier("automix-note")
                    Button {
                        model.startAutomix(seed, length: length, variety: variety)
                        dismiss()
                    } label: {
                        Label(AutomixCopy.start, systemImage: AutomixCopy.symbol)
                            .frame(maxWidth: .infinity, minHeight: Tokens.minHitSize)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("automix-start")
                }
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
        .presentationDetents([.medium, .large])
    }
}
