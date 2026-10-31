import DesignSystem
import MagpieCore
import Requests
import SwiftUI

/// Library › Requests: what Try asked for, grouped In progress / Ready / Needs attention. Tapping a row opens
/// its wait screen (Standard) or a calm detail with no spinner (Patient, D8).
struct ActivityView: View {
    @Environment(AppModel.self) private var model
    /// R16: covers of requests not in the library yet, while the list is open (R15 rules).
    @State private var outsideArt: OutsideArtLoader?
    /// R20: Ready finds a Keep (the leading swipe) is running for, what it said, and Bring in more after a move (D5).
    @State private var keeping: Set<RequestID> = []
    @State private var keepMessage: String?
    @State private var bringingInMore: KeptFind?
    private let themed = Themed()

    var body: some View {
        let groups = Dictionary(grouping: model.requests.reversed()) { RequestCopy.group($0) }
        List {
            if model.isOffline {   // Task 14: requests wait, and nothing can be changed
                OfflineNotice().listRowBackground(Color.clear).listRowSeparator(.hidden)
            }
            ForEach(RequestCopy.Group.allCases, id: \.self) { group in
                if let items = groups[group], !items.isEmpty {
                    Section {
                        ForEach(items) { row($0) }
                    } header: {
                        Text(group.title).magpieDisplay(.title3).foregroundStyle(themed.palette.inkColor)
                            .textCase(nil).accessibilityAddTraits(.isHeader)
                    }
                }
            }
        }
        .listStyle(.plain)
        // Over the list, not a row in it, so no separators frame it (H3 M8).
        .overlay {
            if groups.keys.allSatisfy({ $0 == nil }) {
                ContentUnavailableView("Nothing on its way", systemImage: "tray",
                                       description: Text("Songs you try from Search show up here until they're home."))
                    .accessibilityIdentifier("activity-empty")
            }
        }
        .navigationTitle("Requests")
        .navigationBarTitleDisplayMode(.inline)   // as with rows; an empty list would otherwise show a large title
        .magpieScreen()
        .refreshable { model.pollRequests() }
        .task { if outsideArt == nil { outsideArt = model.makeOutsideArt() } }
        .onDisappear { outsideArt?.reset() }
        .sheet(item: $bringingInMore) { BringInMoreSheet(requestId: $0.id, keptMessage: $0.message) }
        .alert(keepMessage ?? "", isPresented: Binding(get: { keepMessage != nil }, set: { if !$0 { keepMessage = nil } })) {
            Button("OK", role: .cancel) {}
        }
    }

    /// R20: Keep on a Ready find's row (leading swipe, never a full swipe), as on the Finds shelf.
    private func keepAction(_ request: MagpieRequest) -> (() -> Void)? {
        guard !model.isOffline, let id = ReadyFindActions.keep(request), !keeping.contains(id) else { return nil }
        return {
            keeping.insert(id)
            Task {
                let reply = await model.keep(id)
                if reply.bringsInMore {
                    bringingInMore = KeptFind(id: id, message: reply.message)
                } else {
                    keepMessage = reply.message
                }
                keeping.remove(id)
            }
        }
    }

    private func row(_ request: MagpieRequest) -> some View {
        NavigationLink(value: Route.request(request.id)) {
            RequestRow(request: request, context: model.waitContext, outsideArt: outsideArt)
        }
        .listRowBackground(Color.clear)
        .accessibilityIdentifier("request-\(request.recording.title)")
        .swipeActions {
            if !model.isOffline { swipeActions(request) }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            if let keep = keepAction(request) {
                Button(RequestCopy.keep, systemImage: "checkmark.circle", action: keep).tint(.green)
            }
        }
        .accessibilityActions {
            if let keep = keepAction(request) { Button(RequestCopy.keep, action: keep) }
        }
    }

    @ViewBuilder private func swipeActions(_ request: MagpieRequest) -> some View {
        if request.isNotListed {
            Button("Check again") { Task { await model.checkAgain(request.id) } }
        }
        if RequestCopy.canCancel(request.state) {
            Button("Stop looking", role: .destructive) { Task { await model.cancelRequest(request.id) } }
        } else if request.canBeRemoved {
            Button("Remove", role: .destructive) { Task { await model.forgetRequest(request.id) } }
        }
    }
}

/// Title, artist, and the request's status as text + symbol (D3).
struct RequestRow: View {
    let request: MagpieRequest
    var context: RequestCopy.WaitContext = .unknown
    /// R16: the screen's outside artwork; nil shows the library cover once listed, else the bare record.
    var outsideArt: OutsideArtLoader? = nil
    private let themed = Themed()

    var body: some View {
        HStack(spacing: Tokens.Spacing.m) {
            RequestArtwork(cover: request.cover, loader: outsideArt, side: 44) { art in
                RecordArt(image: art, side: 44,
                          isSpinning: RequestCopy.group(request) == .inProgress && request.tier != .patient)
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(request.recording.title).font(.body).lineLimit(2)
                Text(request.recording.artist).font(.footnote).foregroundStyle(themed.palette.ink2Color).lineLimit(1)
                Label(RequestCopy.status(request, context: context), systemImage: RequestCopy.symbol(request))
                    .font(.caption).foregroundStyle(themed.palette.accentInkColor).lineLimit(2)
                if request.tier == .patient, RequestCopy.group(request) == .inProgress {
                    Text(RequestCopy.tierLine(.patient)).font(.caption).foregroundStyle(themed.palette.ink2Color)
                }
            }
        }
        .padding(.vertical, Tokens.Spacing.xs)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(request.recording.title), \(request.recording.artist)")
        .accessibilityValue(RequestCopy.status(request, context: context))
    }
}

/// One request. Standard tier while on its way: the wait screen with real progress. Otherwise (Patient, D8, or
/// needs attention): no spinner, just where it stands. Stop looking cancels (G6); Ready plays it.
/// While it's on screen the app counts the owner as waiting on it: the landing rule (D6, AppModel+Landing.swift)
/// plays it at once when it's ready and nothing else is playing.
struct RequestDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let requestId: RequestID
    /// R20: the Try sheet's line under the stages ("You can keep browsing…") while it's on its way.
    var footnote: String? = nil
    @State private var confirmsStop = false
    /// R20: a Ready find's Keep and Not for me…, with what they said shown on the page.
    @State private var working = false
    @State private var outcome: String?
    @State private var bringingInMore: KeptFind?
    @State private var asking: NotForMeConfirm?
    /// R16: the cover from outside while this screen is open (R15 rules: memory only, fetched again when it opens).
    @State private var outsideArt: OutsideArtLoader?
    private let themed = Themed()

    var body: some View {
        Group {
            if let request = model.magpieRequest(requestId) {
                content(request)
            } else {
                ContentUnavailableView("Not on the list any more", systemImage: "tray")
            }
        }
        // Only the landing rule follows the screen (D6); the request itself is the runner's, which the model owns,
        // so it keeps going when this screen goes (R16).
        .onAppear {
            model.waitScreenAppeared(requestId)
            if outsideArt == nil { outsideArt = model.makeOutsideArt(maxPixel: 600) }
        }
        .onDisappear {
            model.waitScreenDisappeared(requestId)
            outsideArt?.reset()
        }
    }

    @ViewBuilder private func content(_ request: MagpieRequest) -> some View {
        let state = request.state
        VStack(spacing: Tokens.Spacing.l) {
            if request.tier != .patient, RequestCopy.group(request) != .attention {
                RequestArtwork(cover: request.cover, loader: outsideArt, side: 150) { art in   // R16
                    WaitView(title: request.recording.title, artist: subtitle(request), artwork: art,
                             stage: RequestCopy.stage(state), phrase: RequestCopy.phrase(state, tier: request.tier))
                }
                if let footnote, RequestCopy.group(request) == .inProgress {
                    Text(footnote).font(.footnote).foregroundStyle(themed.palette.ink2Color)
                        .multilineTextAlignment(.center).padding(.horizontal, Tokens.Spacing.largeTitleMargin)
                        .accessibilityIdentifier("request-footnote")
                }
            } else {
                calm(request)
            }
            if request.findsUnavailable {
                Text(TryCopy.findsUnavailable).font(.footnote).foregroundStyle(themed.palette.ink2Color)
                    .multilineTextAlignment(.center).padding(.horizontal, Tokens.Spacing.largeTitleMargin)
                    .accessibilityIdentifier("request-finds-unavailable")
            }
            if model.isOffline { OfflineNotice() }
            actions(request)
                .disabled(model.isOffline)   // Task 14: nothing reaches Lidarr or the server offline
        }
        .padding(.bottom, Tokens.Spacing.l)
        .background(themed.palette.bgColor)
        .navigationTitle(RequestCopy.detailTitle(request))
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Stop looking for \(request.recording.title)?", isPresented: $confirmsStop,
                            titleVisibility: .visible) {
            Button("Stop looking", role: .destructive) { Task { await model.cancelRequest(requestId) } }
        } message: {
            Text("Magpie stops asking for it. Nothing is deleted.")
        }
        .confirmationDialog(NotForMeCopy.confirmTitle, isPresented: Binding(get: { asking != nil }, set: { shown in
            if !shown { asking = nil }
        }), titleVisibility: .visible, presenting: asking) { confirm in
            Button(NotForMeCopy.action, role: .destructive) { letGo(confirm) }
            Button("Cancel", role: .cancel) {}
        } message: { confirm in
            Text(confirm.message)
        }
        .sheet(item: $bringingInMore) { BringInMoreSheet(requestId: $0.id, keptMessage: $0.message) }
    }

    private func subtitle(_ r: MagpieRequest) -> String {
        [r.recording.artist, r.albumTitle].compactMap { $0 }.joined(separator: " · ")
    }

    private func calm(_ request: MagpieRequest) -> some View {
        ScrollView {
            VStack(spacing: Tokens.Spacing.m) {
                RequestArtwork(cover: request.cover, loader: outsideArt, side: 150) { RecordArt(image: $0, side: 150) }   // R16
                    .accessibilityHidden(true).padding(.vertical, Tokens.Spacing.l)
                Text(request.recording.title).magpieDisplay(.title2).multilineTextAlignment(.center)
                Text(subtitle(request)).font(.subheadline).foregroundStyle(themed.palette.ink2Color)
                Label(RequestCopy.status(request, context: model.waitContext), systemImage: RequestCopy.symbol(request))
                    .font(.body).foregroundStyle(themed.palette.accentInkColor)
                    .accessibilityIdentifier("request-status")
                if request.tier == .patient, RequestCopy.group(request) == .inProgress {
                    Text("This one might take a while. It can take a few hours. You can leave; it'll be in your \(request.isFind ? "Finds" : "library") when it's home.")
                        .font(.footnote).foregroundStyle(themed.palette.ink2Color).multilineTextAlignment(.center)
                }
                if let note = request.note {
                    Text(note).font(.footnote).foregroundStyle(themed.palette.ink2Color).multilineTextAlignment(.center)
                }
            }
            .padding(Tokens.Spacing.largeTitleMargin)
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder private func actions(_ request: MagpieRequest) -> some View {
        VStack(spacing: Tokens.Spacing.s) {
            if request.state == .ready {
                Button { Task { await play(request) } } label: {
                    Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity, minHeight: Tokens.minHitSize)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("request-play")
                readyFindActions(request)   // R20: Play · Keep · Not for me…
            }
            if let outcome {
                Text(outcome).font(.footnote).foregroundStyle(themed.palette.ink2Color).multilineTextAlignment(.center)
                    .accessibilityIdentifier("request-outcome")
            }
            if request.isNotListed {
                Button("Check again") { Task { await model.checkAgain(requestId) } }
                    .buttonStyle(.bordered)
                    .frame(minHeight: Tokens.minHitSize)
                    .accessibilityIdentifier("request-check-again")
            }
            if RequestCopy.canCancel(request.state) {
                Button("Stop looking", role: .destructive) { confirmsStop = true }
                    .frame(minHeight: Tokens.minHitSize)
                    .accessibilityIdentifier("request-stop")
            } else if !request.cleanupPending, request.state != .ready {
                Button("Remove from the list") {
                    Task {
                        await model.forgetRequest(requestId)
                        dismiss()
                    }
                }
                .frame(minHeight: Tokens.minHitSize)
            }
        }
        .padding(.horizontal, Tokens.Spacing.largeTitleMargin)
    }

    /// R20 (appraisal "R16 / Activity"): a Ready find's Keep, then Not for me… (it asks first). What they said shows
    /// on the page; after a Keep that moved it, Bring in more follows (D5), as on the Finds shelf.
    @ViewBuilder private func readyFindActions(_ request: MagpieRequest) -> some View {
        if let id = ReadyFindActions.keep(request) {
            Button(RequestCopy.keep) {
                working = true
                Task {
                    let reply = await model.keep(id)
                    outcome = reply.message
                    if reply.bringsInMore { bringingInMore = KeptFind(id: id, message: reply.message) }
                    working = false
                }
            }
            .buttonStyle(.bordered)
            .frame(minHeight: Tokens.minHitSize)
            .disabled(working)
            .accessibilityIdentifier("request-keep")
        }
        if let id = ReadyFindActions.notForMe(request) {
            Button(RequestCopy.notForMeAsks, role: .destructive) {
                working = true
                Task {
                    switch await model.notForMeAsk(id) {
                    case .confirm(let confirm): asking = confirm
                    case .message(let text): outcome = text
                    }
                    working = false
                }
            }
            .frame(minHeight: Tokens.minHitSize)
            .disabled(working)
            .accessibilityIdentifier("request-not-for-me")
        }
    }

    private func letGo(_ confirm: NotForMeConfirm) {
        asking = nil
        working = true
        Task {
            outcome = await model.notForMe(confirm)
            working = false
        }
    }

    private func play(_ request: MagpieRequest) async {
        guard let song = await model.readySong(request) else { return }
        model.playReady(song, request: request.id)
    }
}

/// R20: a kept find that moved into the library, for the Bring in more sheet (D5).
struct KeptFind: Identifiable {
    let id: RequestID
    let message: String
}
