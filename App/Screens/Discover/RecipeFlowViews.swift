import AurralKit
import DesignSystem
import SwiftUI

/// Round 16: Discover's Your flows header (New flow) and a row for each recipe flow whose playlist isn't published yet
/// (greyed while it gets its songs; tap to edit, swipe to delete). A published flow shows only as its playlist's row
/// below (owner, 2026-11-05: never twice). Only with accessFlow on a server with flows.
struct YourFlowsSection: View {
    @Environment(AppModel.self) private var model
    @State private var editing: RecipeFlowEditor.Target?
    @State private var deleting: AurralFlow?
    @State private var message: String?
    private let themed = Themed()

    var body: some View {
        if model.aurralCanManageFlows {
            Section {
                ForEach(model.unpublishedRecipeFlows, id: \.id) { flow in
                    Button { editing = .edit(flow) } label: { row(flow) }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("recipe-flow-\(flow.name)")
                        .swipeActions {
                            Button(RecipeFlowCopy.deleteFlow, role: .destructive) { deleting = flow }
                        }
                        .contextMenu {
                            Button(RecipeFlowCopy.editFlow, systemImage: "slider.horizontal.3") { editing = .edit(flow) }
                            Button(RecipeFlowCopy.deleteFlow, systemImage: "trash", role: .destructive) { deleting = flow }
                        }
                        .listRowBackground(Color.clear)
                }
            } header: {
                HStack {
                    Text(RecipeFlowCopy.yourFlows)
                    Spacer()
                    Button(RecipeFlowCopy.newFlow, systemImage: "plus") { editing = .new(model.newFlowRecipe()) }
                        .labelStyle(.titleAndIcon)
                        .font(.subheadline)
                        .accessibilityIdentifier("recipe-flow-new")
                }
            }
            .sheet(item: $editing) { target in RecipeFlowEditor(target: target) }
            // While a flow's songs download in the background, its progress every 10 s.
            .task(id: anyDownloading) {
                guard anyDownloading else { return }
                while !Task.isCancelled, anyDownloading {
                    try? await Task.sleep(for: .seconds(10))
                    await model.refreshDiscoverStatus()
                }
                if !Task.isCancelled { await model.refreshDiscover(force: true) }   // its playlist joins Discover
            }
            .confirmationDialog(RecipeFlowCopy.deleteQuestion, isPresented: Binding(get: { deleting != nil },
                                                                                    set: { if !$0 { deleting = nil } }),
                                titleVisibility: .visible, presenting: deleting) { flow in
                Button(RecipeFlowCopy.deleteFlow, role: .destructive) {
                    Task {
                        do { try await model.deleteRecipeFlow(flow) } catch { message = DiscoverCopy.message(for: error) }
                    }
                }
                .accessibilityIdentifier("recipe-flow-delete-confirm")
            } message: { _ in
                Text(RecipeFlowCopy.deleteNote)
            }
            .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK", role: .cancel) {}
            }
        }
    }

    private var anyDownloading: Bool { model.recipeFlows.contains { model.recipeFlowDownload($0) != nil } }

    /// Owner (2026-11-05): greyed out while its songs are still downloading in the background (still opens to edit).
    private func row(_ flow: AurralFlow) -> some View {
        let download = model.recipeFlowDownload(flow)
        return HStack(spacing: Tokens.Spacing.m) {
            Image(systemName: "wand.and.stars").font(.title3).frame(width: 40, height: 40)
                .foregroundStyle(themed.palette.ink2Color)
            VStack(alignment: .leading, spacing: 1) {
                Text(flow.name).font(.body)
                if let recipe = flow.recipe {
                    Text(RecipeFlowCopy.summary(recipe)).font(.footnote).foregroundStyle(themed.palette.ink2Color)
                    if let download {
                        Label(download.text, systemImage: "arrow.down.circle.dotted")
                            .font(.footnote).foregroundStyle(themed.palette.ink2Color)
                            .accessibilityIdentifier("recipe-flow-downloading")
                    } else {
                        Text(RecipeFlowCopy.schedule(recipe)).font(.footnote).foregroundStyle(themed.palette.ink2Color)
                    }
                }
            }
            Spacer()
            if download != nil { ProgressView().controlSize(.small) }
            Image(systemName: "chevron.right").font(.footnote).foregroundStyle(themed.palette.ink2Color)
        }
        .opacity(download == nil ? 1 : 0.45)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// Round 16: the recipe editor (New flow, Edit flow): Simple shows the everyday fields, Advanced adds tags to leave out,
/// similar artists, recent listening and automatic download. Switching never drops a value.
/// Round 27 D2 (owner item 13, 2026-11-14): both ask for a number of songs per source (a checkmark and a stepper each),
/// with "N songs in all" below, as Aurral's editor does; the size field and the share sliders are gone (D316).
struct RecipeFlowEditor: View {
    @Environment(\.discoverLayoutProbe) private var probe
    enum Target: Identifiable {
        case new(FlowRecipe)
        case edit(AurralFlow)
        var id: String {
            switch self {
            case .new: "new"
            case .edit(let flow): flow.id
            }
        }
    }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let target: Target
    @State private var recipe: FlowRecipe
    @State private var advanced: Bool
    @State private var working = false
    @State private var confirmingDelete = false
    @State private var message: String?

    init(target: Target) {
        self.target = target
        let recipe: FlowRecipe = switch target {
        case .new(let r): r
        case .edit(let flow): flow.recipe ?? FlowRecipe(name: flow.name)
        }
        _recipe = State(initialValue: recipe)
        _advanced = State(initialValue: recipe.usesAdvanced)
    }

    private var flow: AurralFlow? { if case .edit(let f) = target { f } else { nil } }
    private var original: FlowRecipe? { flow?.recipe }
    private var problem: String? { AppModel.prepared(recipe).problem }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("", selection: $advanced) {
                        Text(RecipeFlowCopy.simple).tag(false)
                        Text(RecipeFlowCopy.advanced).tag(true)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("recipe-flow-mode")
                    TextField(RecipeFlowCopy.name, text: $recipe.name)
                        .accessibilityIdentifier("recipe-flow-name")
                } footer: {
                    if !advanced, recipe.usesAdvanced { Text(RecipeFlowCopy.usesAdvanced) }
                }
                sourcesSection
                Section {
                    Toggle(RecipeFlowCopy.deeperCuts, isOn: $recipe.deepDive)
                        .accessibilityIdentifier("recipe-flow-deeper-cuts")
                } footer: { Text(RecipeFlowCopy.deeperCutsNote) }
                scheduleSection
                Section(RecipeFlowCopy.tags) {
                    TextList(items: $recipe.tags, prompt: RecipeFlowCopy.addTag, id: "tags")
                }
                yearsSection
                if advanced {
                    Section(RecipeFlowCopy.excludeTags) {
                        TextList(items: $recipe.excludeTags, prompt: RecipeFlowCopy.addExcludeTag, id: "exclude-tags")
                    }
                    Section(RecipeFlowCopy.similarTo) {
                        TextList(items: $recipe.relatedArtists, prompt: RecipeFlowCopy.addArtist, id: "similar")
                    }
                    Section {
                        Toggle(RecipeFlowCopy.recentListening, isOn: $recipe.recentListening)
                        Toggle(RecipeFlowCopy.autoDownload, isOn: $recipe.autoDownload)
                    }
                }
                if flow != nil {
                    Section {
                        Button(RecipeFlowCopy.deleteFlow, role: .destructive) { confirmingDelete = true }
                            .accessibilityIdentifier("recipe-flow-delete")
                    }
                }
            }
            .disabled(working)
            .navigationTitle(flow == nil ? RecipeFlowCopy.newFlow : RecipeFlowCopy.editFlow)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(RecipeFlowCopy.cancel) { dismiss() }.accessibilityIdentifier("recipe-flow-cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    if working {
                        ProgressView()
                    } else if let flow {
                        Button(RecipeFlowCopy.save) { Task { await run { try await model.updateRecipeFlow(flow, to: recipe) } } }
                            .disabled(problem != nil || recipe == original)
                            .accessibilityIdentifier("recipe-flow-save")
                    } else {
                        Button(RecipeFlowCopy.create) { Task { await run { try await model.createRecipeFlow(recipe) } } }
                            .disabled(problem != nil)
                            .accessibilityIdentifier("recipe-flow-create")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Text(problem ?? (flow == nil ? RecipeFlowCopy.createNote : RecipeFlowCopy.editNote))
                    .font(.footnote).foregroundStyle(problem == nil ? Color.secondary : Color.red)
                    .frame(maxWidth: .infinity).padding(Tokens.Spacing.s).background(.bar)
                    .accessibilityIdentifier("recipe-flow-note")
            }
            .confirmationDialog(RecipeFlowCopy.deleteQuestion, isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button(RecipeFlowCopy.deleteFlow, role: .destructive) {
                    if let flow { Task { await run { try await model.deleteRecipeFlow(flow) } } }
                }
            } message: {
                Text(RecipeFlowCopy.deleteNote)
            }
            .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK", role: .cancel) {}
            }
        }
    }

    /// Round 27 D2: each source's count (Simple and Advanced alike), the total below (D316).
    private var sourcesSection: some View {
        Section {
            ForEach(FlowSource.allCases, id: \.self) { source in
                SourceCountRow(source: source, recipe: $recipe)
            }
        } header: {
            Text(RecipeFlowCopy.sources)
        } footer: {
            Text(RecipeFlowCountCopy.songsInAll(recipe.size))
                .monospacedDigit()
                .accessibilityIdentifier("recipe-flow-total")
                .discoverProbe(probe, "total:" + RecipeFlowCountCopy.songsInAll(recipe.size))
        }
    }

    private var scheduleSection: some View {
        Section {
            HStack(spacing: Tokens.Spacing.xs) {
                ForEach(0..<7, id: \.self) { day in
                    let on = recipe.scheduleDays.contains(day)
                    Button(RecipeFlowCopy.dayLetters[day]) {
                        if on { recipe.scheduleDays.removeAll { $0 == day } } else { recipe.scheduleDays = (recipe.scheduleDays + [day]).sorted() }
                    }
                    .buttonStyle(.bordered)
                    .tint(on ? .accentColor : .secondary)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel(RecipeFlowCopy.dayNames[day])
                    .accessibilityAddTraits(on ? .isSelected : [])
                    .accessibilityIdentifier("recipe-flow-day-\(day)")
                }
            }
            Picker(RecipeFlowCopy.time, selection: $recipe.scheduleHour) {
                ForEach(0..<24, id: \.self) { Text(RecipeFlowCopy.hour($0)).tag($0) }
            }
            .accessibilityIdentifier("recipe-flow-hour")
        } header: {
            Text(RecipeFlowCopy.updates)
        } footer: {
            if !recipe.scheduleDays.isEmpty { Text(RecipeFlowCopy.schedule(recipe)) }
        }
    }

    private var yearsSection: some View {
        let years = Array((1900...Calendar.current.component(.year, from: Date())).reversed())
        return Section(RecipeFlowCopy.released) {
            Picker(RecipeFlowCopy.from, selection: $recipe.yearFrom) {
                Text(RecipeFlowCopy.anyYear).tag(Int?.none)
                ForEach(years, id: \.self) { Text(String($0)).tag(Int?.some($0)) }
            }
            .accessibilityIdentifier("recipe-flow-year-from")
            Picker(RecipeFlowCopy.to, selection: $recipe.yearTo) {
                Text(RecipeFlowCopy.anyYear).tag(Int?.none)
                ForEach(years, id: \.self) { Text(String($0)).tag(Int?.some($0)) }
            }
            .accessibilityIdentifier("recipe-flow-year-to")
        }
    }

    /// Sends the change; closes on success, says why otherwise.
    private func run(_ change: @escaping () async throws -> Any) async {
        working = true
        defer { working = false }
        do {
            _ = try await change()
            dismiss()
        } catch let error as RecipeFlowError {
            message = error.message
        } catch {
            message = DiscoverCopy.message(for: error)
        }
    }
}

/// Round 27 D2 (owner item 13, 2026-11-14): one source's songs: a checkmark (on gives it ten, off none) and "N songs"
/// with minus and plus (a tap steps one, a long press five; 0–100). One VoiceOver element, "<Source>, N songs",
/// adjustable; activating it checks or unchecks the source (D316).
private struct SourceCountRow: View {
    @Environment(\.discoverLayoutProbe) private var probe
    let source: FlowSource
    @Binding var recipe: FlowRecipe

    private var count: Int { recipe.counts[source] ?? 0 }

    var body: some View {
        let on = count > 0
        HStack(spacing: Tokens.Spacing.s) {
            Image(systemName: on ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(on ? Color.accentColor : Color.secondary)
                .frame(minWidth: Tokens.minHitSize, minHeight: Tokens.minHitSize)
                .contentShape(Rectangle())
                .onTapGesture { recipe.setSource(source, on: !on) }
            Text(RecipeFlowCopy.source(source))
            Spacer(minLength: Tokens.Spacing.s)
            Text(RecipeFlowCopy.songs(count)).monospacedDigit().foregroundStyle(on ? Color.primary : Color.secondary)
            stepButton("minus.circle", by: -1, enabled: count > 0)
            stepButton("plus.circle", by: 1, enabled: count < FlowRecipe.maxSongs)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(RecipeFlowCountCopy.sourceLabel(source, count))
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: RecipeFlowCountCopy.step(&recipe, source, by: 1)
            case .decrement: RecipeFlowCountCopy.step(&recipe, source, by: -1)
            @unknown default: break
            }
        }
        .accessibilityAction { recipe.setSource(source, on: !on) }
        .accessibilityIdentifier("recipe-flow-source-\(source.rawValue)")
        .discoverProbe(probe, "source:" + RecipeFlowCountCopy.sourceLabel(source, count))
    }

    /// A tap steps one, a long press five (`RecipeFlowCountCopy.longPressStep`).
    private func stepButton(_ symbol: String, by step: Int, enabled: Bool) -> some View {
        Image(systemName: symbol)
            .font(.title2)
            .foregroundStyle(enabled ? Color.accentColor : Color.secondary.opacity(0.5))
            .frame(minWidth: Tokens.minHitSize, minHeight: Tokens.minHitSize)
            .contentShape(Rectangle())
            .onTapGesture { if enabled { RecipeFlowCountCopy.step(&recipe, source, by: step) } }
            .onLongPressGesture(minimumDuration: 0.4) {
                if enabled { RecipeFlowCountCopy.step(&recipe, source, by: step * RecipeFlowCountCopy.longPressStep) }
            }
            .accessibilityIdentifier("recipe-flow-\(step > 0 ? "more" : "fewer")-\(source.rawValue)")
    }
}

/// Round 27 D2: the count editor's words and steps (D316; copy as plan §8).
enum RecipeFlowCountCopy {
    /// What a long press on minus or plus steps by.
    static let longPressStep = 5

    /// "30 songs in all".
    static func songsInAll(_ n: Int) -> String { "\(RecipeFlowCopy.songs(n)) in all" }

    /// VoiceOver: "Library, 12 songs".
    static func sourceLabel(_ source: FlowSource, _ n: Int) -> String {
        "\(RecipeFlowCopy.source(source)), \(RecipeFlowCopy.songs(n))"
    }

    /// Steps a source's count, held to 0–100.
    static func step(_ recipe: inout FlowRecipe, _ source: FlowSource, by step: Int) {
        recipe.counts[source] = min(max((recipe.counts[source] ?? 0) + step, 0), FlowRecipe.maxSongs)
    }
}

/// A list of short texts (tags, artists): each removable, one added at a time.
private struct TextList: View {
    @Binding var items: [String]
    let prompt: String
    let id: String
    @State private var draft = ""

    var body: some View {
        ForEach(items, id: \.self) { item in Text(item) }
            .onDelete { items.remove(atOffsets: $0) }
        HStack {
            TextField(prompt, text: $draft)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit(add)
                .accessibilityIdentifier("recipe-flow-\(id)-field")
            if !draft.trimmingCharacters(in: .whitespaces).isEmpty {
                Button("Add", systemImage: "plus.circle.fill", action: add).labelStyle(.iconOnly)
            }
        }
    }

    private func add() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        guard !text.isEmpty, items.count < FlowRecipe.maxListItems,
              !items.contains(where: { $0.lowercased() == text.lowercased() }) else { return }
        items.append(String(text.prefix(FlowRecipe.maxItemLength)))
    }
}
