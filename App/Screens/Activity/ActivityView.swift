import DesignSystem
import MagpieCore
import Requests
import SwiftUI

/// Library › Requests: what Try asked for, grouped In progress / Ready / Needs attention. Tapping a row opens
/// its wait screen (Standard) or a calm detail with no spinner (Patient, D8).
struct ActivityView: View {
    @Environment(AppModel.self) private var model
    private let themed = Themed()

    var body: some View {
        let groups = Dictionary(grouping: model.requests.reversed()) { RequestCopy.group($0) }
        List {
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
    }

    private func row(_ request: MagpieRequest) -> some View {
        NavigationLink(value: Route.request(request.id)) {
            RequestRow(request: request, context: model.waitContext)
        }
        .listRowBackground(Color.clear)
        .accessibilityIdentifier("request-\(request.recording.title)")
        .swipeActions {
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
}

/// Title, artist, and the request's status as text + symbol (D3).
struct RequestRow: View {
    let request: MagpieRequest
    var context: RequestCopy.WaitContext = .unknown
    private let themed = Themed()

    var body: some View {
        HStack(spacing: Tokens.Spacing.m) {
            RecordArt(side: 44, isSpinning: RequestCopy.group(request) == .inProgress && request.tier != .patient)
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
    @State private var confirmsStop = false
    private let themed = Themed()

    var body: some View {
        Group {
            if let request = model.magpieRequest(requestId) {
                content(request)
            } else {
                ContentUnavailableView("Not on the list any more", systemImage: "tray")
            }
        }
        .onAppear { model.waitScreenAppeared(requestId) }
        .onDisappear { model.waitScreenDisappeared(requestId) }
    }

    @ViewBuilder private func content(_ request: MagpieRequest) -> some View {
        let state = request.state
        VStack(spacing: Tokens.Spacing.l) {
            if request.tier != .patient, RequestCopy.group(request) != .attention {
                WaitView(title: request.recording.title, artist: subtitle(request), stage: RequestCopy.stage(state),
                         phrase: RequestCopy.phrase(state, tier: request.tier))
            } else {
                calm(request)
            }
            if request.findsUnavailable {
                Text(TryCopy.findsUnavailable).font(.footnote).foregroundStyle(themed.palette.ink2Color)
                    .multilineTextAlignment(.center).padding(.horizontal, Tokens.Spacing.largeTitleMargin)
                    .accessibilityIdentifier("request-finds-unavailable")
            }
            actions(request)
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
    }

    private func subtitle(_ r: MagpieRequest) -> String {
        [r.recording.artist, r.albumTitle].compactMap { $0 }.joined(separator: " · ")
    }

    private func calm(_ request: MagpieRequest) -> some View {
        ScrollView {
            VStack(spacing: Tokens.Spacing.m) {
                RecordArt(side: 150).accessibilityHidden(true).padding(.vertical, Tokens.Spacing.l)
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

    private func play(_ request: MagpieRequest) async {
        guard let song = await model.readySong(request) else { return }
        model.playReady(song, request: request.id)
    }
}
