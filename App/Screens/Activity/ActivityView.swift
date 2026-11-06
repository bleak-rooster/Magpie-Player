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
    @State private var addingMore: AddFlowRequest?
    /// Y5: "Remove the MP3 now" asks first (and says when it can't be undone, I7).
    @State private var removingMP3: MagpieRequest?
    @State private var mp3Permanent = true
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
        .addFlow($addingMore) { keepMessage = $0.message }
        .alert(keepMessage ?? "", isPresented: Binding(get: { keepMessage != nil }, set: { if !$0 { keepMessage = nil } })) {
            Button("OK", role: .cancel) {}
        }
        .confirmationDialog(FindCopy.removeMP3Title,
                            isPresented: Binding(get: { removingMP3 != nil }, set: { if !$0 { removingMP3 = nil } }),
                            titleVisibility: .visible, presenting: removingMP3) { request in
            Button("Remove", role: .destructive) {
                Task { keepMessage = await model.removeMP3Now(request.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text(FindCopy.confirmMessage(permanent: mp3Permanent))
        }
    }

    /// Y5: "Remove the MP3 now" on a kept find whose MP3 Magpie recorded.
    private func removeMP3Action(_ request: MagpieRequest) -> (() -> Void)? {
        guard !model.isOffline, model.canRemoveMP3(request) else { return nil }
        return {
            Task {
                mp3Permanent = await model.mp3RemovalIsPermanent()
                removingMP3 = request
            }
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
                    addingMore = model.afterKeepRequest(id, artist: request.recording.artist, kept: reply.message)
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
            if let remove = removeMP3Action(request) { Button(FindCopy.removeMP3, action: remove) }
        }
    }

    @ViewBuilder private func swipeActions(_ request: MagpieRequest) -> some View {
        if request.isNotListed {
            Button("Check again") { Task { await model.checkAgain(request.id) } }
        }
        if let remove = removeMP3Action(request) {
            Button(FindCopy.removeMP3, systemImage: "trash", action: remove).tint(.orange)
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
            RequestArtwork(cover: request.cover, loader: outsideArt, side: 44) { art in   // R16
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
    /// Under the stages (the Try sheet's "You can keep browsing…", R20).
    var footnote: String? = nil
    @State private var confirmsStop = false
    // R17 / R20: Find another copy, and a Ready find's Keep and Not for me.
    @State private var confirmsAnotherCopy = false
    @State private var anotherCopyNote: String?
    @State private var working = false
    @State private var message: String?
    @State private var asking: NotForMeConfirm?
    /// R16: the cover from outside while this screen is open (R15 rules: memory only, fetched again when it opens).
    @State private var outsideArt: OutsideArtLoader?
    /// R20: after a Keep that moved the find, "Kept. Add more from <artist>?" (the Add sheet, X7).
    @State private var addingMore: AddFlowRequest?
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
                             stage: RequestCopy.stage(state), phrase: RequestCopy.phrase(request))
                }
            } else {
                calm(request)
            }
            if let footnote, RequestCopy.group(request) == .inProgress {
                Text(footnote).font(.footnote).foregroundStyle(themed.palette.ink2Color)
                    .multilineTextAlignment(.center).padding(.horizontal, Tokens.Spacing.largeTitleMargin)
                    .accessibilityIdentifier("request-footnote")
            }
            if request.findsUnavailable {
                Text(TryCopy.findsUnavailable).font(.footnote).foregroundStyle(themed.palette.ink2Color)
                    .multilineTextAlignment(.center).padding(.horizontal, Tokens.Spacing.largeTitleMargin)
                    .accessibilityIdentifier("request-finds-unavailable")
            }
            if model.isOffline { OfflineNotice() }
            actions(request)
                .disabled(model.isOffline)   // Task 14: nothing reaches Lidarr or the server offline
            KeptSingleRequestSection(request: request)   // R22 (D171): keep or remove the kept single
        }
        .padding(.bottom, Tokens.Spacing.l)
        .background(themed.palette.bgColor)
        .navigationTitle(RequestCopy.detailTitle(request))
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Stop looking for \(request.recording.title)?", isPresented: $confirmsStop,
                            titleVisibility: .visible) {
            Button("Stop looking", role: .destructive) { Task { await model.cancelRequest(requestId) } }
        } message: {
            Text("Magpie stops asking for it, and cancels a download it started. Nothing in your library is deleted.")
        }
        .confirmationDialog(RequestCopy.findAnotherTitle, isPresented: $confirmsAnotherCopy, titleVisibility: .visible) {
            Button(RequestCopy.findAnotherCopy, role: .destructive) { Task { await findAnotherCopy(removingCopy: true) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(RequestCopy.findAnotherMessage)
        }
        .confirmationDialog(NotForMeCopy.confirmTitle, isPresented: Binding(get: { asking != nil },
                                                                            set: { if !$0 { asking = nil } }),
                            titleVisibility: .visible, presenting: asking) { confirm in
            Button(NotForMeCopy.action, role: .destructive) { letGo(confirm) }
            Button("Cancel", role: .cancel) {}
        } message: { confirm in
            Text(confirm.message)
        }
        .addFlow($addingMore) { message = $0.message }
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
            ForEach(RequestPageAction.actions(for: request), id: \.self) { action(request, $0) }
            if let message {
                Text(message).font(.footnote).foregroundStyle(themed.palette.ink2Color).multilineTextAlignment(.center)
                    .accessibilityIdentifier("request-message")
            }
        }
        .padding(.horizontal, Tokens.Spacing.largeTitleMargin)
    }

    @ViewBuilder private func action(_ request: MagpieRequest, _ action: RequestPageAction) -> some View {
        switch action {
        case .play:
            // Y7: the design system's action capsules (Play filled, the rest tinted), not iOS's bordered styles.
            ActionButton("Play", symbol: "play.fill", prominence: .primary) { Task { await play(request) } }
                .accessibilityIdentifier("request-play")
        case .keep:
            ActionButton("Keep", symbol: "plus.circle") { Task { await keep() } }
                .disabled(working)
            .accessibilityIdentifier("request-keep")
        case .notForMe:
            Button(NotForMeCopy.action + "…", role: .destructive) { Task { await askNotForMe() } }
                .frame(minHeight: Tokens.minHitSize)
                .disabled(working)
                .accessibilityIdentifier("request-not-for-me")
        case .findAnotherCopy:
            // Once per 30 s: the clock only re-enables the button on this screen (nothing is read from the servers).
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let hold = model.findAnotherCopyHold(request, now: context.date)
                VStack(spacing: Tokens.Spacing.xs) {
                    ActionButton(RequestCopy.findAnotherCopy, symbol: "arrow.triangle.2.circlepath") {
                        Task { await findAnotherCopy(removingCopy: false) }
                    }
                    .disabled(working || hold != nil)
                    .accessibilityIdentifier("request-find-another-copy")
                    if let note = hold ?? anotherCopyNote {
                        Text(note).font(.footnote)
                            .foregroundStyle(themed.palette.ink2Color).multilineTextAlignment(.center)
                            .accessibilityIdentifier("request-find-another-note")
                    }
                }
            }
        case .checkAgain:
            ActionButton("Check again", symbol: "arrow.clockwise") { Task { await model.checkAgain(requestId) } }
                .accessibilityIdentifier("request-check-again")
        case .stopLooking:
            Button("Stop looking", role: .destructive) { confirmsStop = true }
                .frame(minHeight: Tokens.minHitSize)
                .accessibilityIdentifier("request-stop")
        case .includeSingles:
            ActionButton(LibraryFindsCopy.includeSingles, symbol: "music.note.list") {
                Task { await model.includeSinglesForRequest(request) }
            }
            .accessibilityIdentifier("request-include-singles")
        case .remove:
            Button("Remove from the list") {
                Task {
                    await model.forgetRequest(requestId)
                    dismiss()
                }
            }
            .frame(minHeight: Tokens.minHitSize)
        }
    }

    /// Asks first only when there's a copy coming (the runner reads Lidarr's queue; nothing is sent before the OK).
    private func findAnotherCopy(removingCopy: Bool) async {
        working = true
        defer { working = false }
        switch await model.findAnotherCopy(requestId, removingCopy: removingCopy) {
        case .started, .tooSoon: anotherCopyNote = nil
        case .needsConfirmation: confirmsAnotherCopy = true
        case .failed(let text): anotherCopyNote = text
        }
    }

    /// Keep, as in Finds: the Add sheet follows a move (D5, R20); otherwise what happened shows here.
    private func keep() async {
        working = true
        defer { working = false }
        let reply = await model.keep(requestId)
        if reply.bringsInMore, let request = model.requests.first(where: { $0.id == requestId }) {
            addingMore = model.afterKeepRequest(requestId, artist: request.recording.artist, kept: reply.message)
        } else {
            message = reply.message
        }
    }

    private func askNotForMe() async {
        working = true
        defer { working = false }
        switch await model.notForMeAsk(requestId) {
        case .confirm(let confirm): asking = confirm
        case .message(let text): message = text
        }
    }

    private func letGo(_ confirm: NotForMeConfirm) {
        asking = nil
        Task {
            working = true
            message = await model.notForMe(confirm)
            working = false
        }
    }

    private func play(_ request: MagpieRequest) async {
        guard let song = await model.readySong(request) else { return }
        model.playReady(song, request: request.id)
    }
}

