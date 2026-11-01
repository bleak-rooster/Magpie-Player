import DesignSystem
import LidarrKit
import MagpieCore
import Requests
import SwiftUI

/// R18 + R20: the one Add sheet (Add to your library, Add more to your library, and Add more after a Keep). What to
/// add (whole-artist kinds, "Just this album" only with an album in context), the kinds (Studio on by default, Live,
/// Soundtracks; Official applied silently), the quality (Lossless or Smaller files) and Follow new releases, each row
/// with "about N hours" when known. Preset with Settings › New music › When you add an artist. Several artists of the
/// name: "Which <artist>?" first. It closes when the add went through; a failure stays, said plainly.
struct AddSheet: View {
    @Environment(\.dismiss) private var dismiss
    let request: AddFlowRequest
    let preset: DownloadChoices
    let onFinish: (AddOutcome) -> Void

    @State private var choices: DownloadChoices
    @State private var picked: ArtistLidarr.Candidate?
    @State private var sizes: [AddWhat: AddSize] = [:]
    @State private var loadingSizes = true
    @State private var working = false
    @State private var failure: String?
    private let themed = Themed()

    init(request: AddFlowRequest, preset: DownloadChoices, onFinish: @escaping (AddOutcome) -> Void) {
        self.request = request
        self.preset = preset
        self.onFinish = onFinish
        _choices = State(initialValue: preset)
        _picked = State(initialValue: request.candidates.count == 1 ? request.candidates[0] : nil)
    }

    private var needsPick: Bool { request.candidates.count > 1 && picked == nil }

    var body: some View {
        NavigationStack {
            Form {
                if case .afterKeep(let kept) = request.kind {
                    Section {
                        Label(kept, systemImage: "checkmark.seal")
                            .foregroundStyle(themed.palette.accentInkColor)
                            .accessibilityIdentifier("add-kept")
                    }
                }
                if needsPick { pickSection } else { choiceSections }
            }
            .navigationTitle(NewMusicCopy.title(request.kind, request.artist))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NewMusicCopy.cancel(request.kind)) { dismiss() }
                        .accessibilityIdentifier("add-cancel")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .task(id: choices.types) {
            loadingSizes = true
            sizes = await request.sizes(choices.types)
            loadingSizes = false
        }
    }

    // MARK: - Which artist

    private var pickSection: some View {
        Section {
            ForEach(request.candidates) { candidate in
                Button(candidate.label) { picked = candidate }
                    .accessibilityIdentifier("add-candidate-\(candidate.id)")
            }
        } header: {
            Text(NewMusicCopy.whichArtist(request.artist))
        }
    }

    // MARK: - Choices

    @ViewBuilder private var choiceSections: some View {
        let p = themed.palette
        Section {
            ForEach(rows) { what in whatRow(what) }
            if loadingSizes {
                Label(NewMusicCopy.loading, systemImage: "hourglass").font(.footnote).foregroundStyle(p.ink2Color)
            }
        } header: {
            Text(NewMusicCopy.whatHeader)
        } footer: {
            if NewMusicCopy.isLotOfMusic(selectedSize?.duration) {
                Text(NewMusicCopy.lotOfMusic).accessibilityIdentifier("add-lot")
            }
        }
        if choices.what == .wholeArtist {
            Section(NewMusicCopy.kindsHeader) {
                Toggle(NewMusicCopy.studio, isOn: $choices.types.studio).accessibilityIdentifier("add-studio")
                Toggle(NewMusicCopy.live, isOn: $choices.types.live).accessibilityIdentifier("add-live")
                Toggle(NewMusicCopy.soundtracks, isOn: $choices.types.soundtrack).accessibilityIdentifier("add-soundtracks")
            }
        }
        Section(NewMusicCopy.qualityHeader) {
            Picker(NewMusicCopy.qualityHeader, selection: $choices.quality) {
                ForEach(DownloadChoices.Quality.allCases, id: \.self) { Text(NewMusicCopy.quality($0)).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("add-quality")
        }
        Section {
            Toggle(NewMusicCopy.follow, isOn: $choices.follow).accessibilityIdentifier("add-follow")
        } footer: {
            Text(NewMusicCopy.followNote)
        }
        Section {
            Button { Task { await commit() } } label: {
                HStack {
                    if working { ProgressView() }
                    Text(NewMusicCopy.primary(request.kind)).bold()
                }
                .frame(maxWidth: .infinity, minHeight: Tokens.minHitSize)
            }
            .disabled(working)
            .accessibilityIdentifier("add-start")
            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(p.ink2Color)
                    .accessibilityIdentifier("add-error")
            }
        }
    }

    private var rows: [AddWhat] {
        [.albumsAndEPs, .albums, .everything] + (request.albumContext ? [.thisAlbum] : [])
    }

    private var selectedSize: AddSize? { sizes[AddWhat(choices)] }

    /// One "What to add" row: its name, "about N hours" when known, and a check when it's the one (text + symbol, D3).
    private func whatRow(_ what: AddWhat) -> some View {
        let p = themed.palette
        let isOn = AddWhat(choices) == what
        return Button { choices = what.applied(to: choices) } label: {
            HStack(spacing: Tokens.Spacing.m) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(NewMusicCopy.what(what)).foregroundStyle(p.inkColor)
                    if let hours = NewMusicCopy.hours(sizes[what]?.duration) {
                        Text(hours).font(.footnote).foregroundStyle(p.ink2Color)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isOn ? p.accentInkColor : p.ink2Color)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: Tokens.minHitSize)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityIdentifier("add-what-\(what.rawValue)")
    }

    private func commit() async {
        working = true
        failure = nil
        let outcome = await request.commit(choices, picked, selectedSize)
        working = false
        if outcome.succeeded {
            onFinish(outcome)
            dismiss()
        } else {
            failure = outcome.message
        }
    }
}

/// Presents an Add: one confirmation with the defaults' one-line summary when Add with my defaults is on, else the
/// Add sheet preset with them (`AddRoute`). `onFinish` hears how it went (from either).
private struct AddFlowModifier: ViewModifier {
    @Environment(AppModel.self) private var model
    @Binding var request: AddFlowRequest?
    let onFinish: (AddOutcome) -> Void

    @State private var sheet: SheetItem?
    @State private var confirm: ConfirmItem?

    struct SheetItem: Identifiable {
        let request: AddFlowRequest
        let preset: DownloadChoices
        var id: UUID { request.id }
    }

    struct ConfirmItem {
        let request: AddFlowRequest
        let choices: DownloadChoices
        let summary: String
        let size: AddSize?
    }

    func body(content: Content) -> some View {
        content
            .onChange(of: request?.id, initial: true) {
                guard let asked = request else { return }
                request = nil
                switch AddRoute.route(withMyDefaults: model.newMusic.withMyDefaults, defaults: model.newMusic.whenYouAdd,
                                      albumContext: asked.albumContext, candidates: asked.candidates.count) {
                case .sheet(let preset):
                    sheet = SheetItem(request: asked, preset: preset)
                case .confirm(let choices):
                    // Shown at once (review M6: never a dead tap); the length fills in when Lidarr has said it.
                    confirm = ConfirmItem(request: asked, choices: choices,
                                          summary: NewMusicCopy.summary(choices, duration: nil), size: nil)
                    Task {
                        let size = await asked.sizes(choices.types)[AddWhat(choices)]
                        guard let shown = confirm, shown.request.id == asked.id, size != nil else { return }
                        confirm = ConfirmItem(request: asked, choices: choices,
                                              summary: NewMusicCopy.summary(choices, duration: size?.duration), size: size)
                    }
                }
            }
            .sheet(item: $sheet) { item in
                AddSheet(request: item.request, preset: item.preset, onFinish: onFinish)
            }
            .alert(confirm.map { NewMusicCopy.confirmTitle($0.request.kind, $0.request.artist) } ?? "",
                   isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
                   presenting: confirm) { item in
                Button(NewMusicCopy.primary(item.request.kind)) {
                    Task { onFinish(await item.request.commit(item.choices, item.request.candidates.first, item.size)) }
                }
                .accessibilityIdentifier("add-confirm")
                Button(NewMusicCopy.cancel(item.request.kind), role: .cancel) {}
            } message: { item in
                Text(item.summary + (NewMusicCopy.isLotOfMusic(item.size?.duration) ? "\n\n" + NewMusicCopy.lotOfMusic : ""))
            }
    }
}

extension View {
    /// Shows an Add when `request` is set (and clears it): the sheet or one confirmation (R18, R20).
    func addFlow(_ request: Binding<AddFlowRequest?>, onFinish: @escaping (AddOutcome) -> Void) -> some View {
        modifier(AddFlowModifier(request: request, onFinish: onFinish))
    }
}
