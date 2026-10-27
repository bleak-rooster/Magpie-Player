import DesignSystem
import MagpieCore
import Requests
import SwiftUI

/// Try on a song that's not in the library: into Finds when they're set up (Task 6.2a), else straight into
/// the library (fallback mode, M5, B8). Standard tier: "Try it", then the wait screen.
/// Patient tier (D8): "Ask for it", a confirmation, and no spinning wait screen; it shows up in Requests.
/// When Try isn't possible yet, says why calmly and opens Settings.
struct TrySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let recording: ExternalRecording

    enum Phase: Equatable {
        case choosing
        case working
        case waiting(RequestID)
        case asked(RequestID)
    }

    @State private var phase = Phase.choosing
    @State private var error: String?
    @State private var showsSettings = false
    private let themed = Themed()

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .choosing, .working: choosing
                case .waiting(let id): RequestDetailView(requestId: id)
                case .asked(let id): asked(id)
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(isWaiting ? "Leave" : "Done") { dismiss() }
                        .accessibilityHint(isWaiting ? "It keeps coming. Find it in Library, Requests." : "")
                        .accessibilityIdentifier("try-done")
                }
            }
        }
        .sheet(isPresented: $showsSettings) { SettingsView() }
    }

    private var isWaiting: Bool { if case .waiting = phase { true } else { false } }

    // MARK: - Choosing

    private var choosing: some View {
        let p = themed.palette
        let availability = model.tryAvailability
        return ScrollView {
            VStack(spacing: Tokens.Spacing.l) {
                RecordArt(side: 140).accessibilityHidden(true).padding(.top, Tokens.Spacing.xl)
                VStack(spacing: Tokens.Spacing.xs) {
                    Text(recording.title).magpieDisplay(.title2).multilineTextAlignment(.center)
                    Text(details).font(.subheadline).foregroundStyle(p.ink2Color).multilineTextAlignment(.center)
                    Label("Not in your library yet", systemImage: "record.circle")
                        .font(.footnote).foregroundStyle(p.accentInkColor)
                }
                switch availability {
                case .available(let tier):
                    VStack(spacing: Tokens.Spacing.s) {
                        Text(RequestCopy.tierLine(tier)).font(.subheadline.weight(.semibold))
                            .accessibilityIdentifier("try-tier")
                        Text(model.tryNote).font(.footnote).foregroundStyle(p.ink2Color)
                            .multilineTextAlignment(.center)
                            .accessibilityIdentifier(model.triesGoIntoFinds ? "try-finds-note" : "try-fallback-note")
                    }
                    if let error {
                        Label(error, systemImage: "exclamationmark.circle").font(.footnote)
                            .foregroundStyle(p.ink2Color).multilineTextAlignment(.center)
                            .accessibilityIdentifier("try-error")
                    }
                    Button { Task { await start(tier) } } label: {
                        HStack {
                            if phase == .working { ProgressView() }
                            Text(tier.asksInsteadOfWaiting ? "Ask for it" : "Try it")
                        }
                        .frame(maxWidth: .infinity, minHeight: Tokens.minHitSize)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(phase == .working)
                    .accessibilityIdentifier("try-start")
                default:
                    Text(availability.message ?? "").font(.body).multilineTextAlignment(.center)
                        .accessibilityIdentifier("turn-on-changes-message")
                    Button("Open Settings") { showsSettings = true }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("try-open-settings")
                }
            }
            .padding(.horizontal, Tokens.Spacing.largeTitleMargin)
            .padding(.bottom, Tokens.Spacing.xxl)
            .frame(maxWidth: .infinity)
        }
        .background(p.bgColor)
    }

    private var details: String {
        var parts = [recording.artist]
        if let album = recording.releaseTitle, !album.isEmpty { parts.append(album) }
        if let d = recording.duration, d > 0 { parts.append(DurationText.clock(d)) }
        return parts.joined(separator: " · ")
    }

    private func start(_ tier: Tier) async {
        error = nil
        phase = .working
        do {
            let id = try await model.tryRecording(recording)
            phase = tier.asksInsteadOfWaiting ? .asked(id) : .waiting(id)
        } catch {
            self.error = TryCopy.message(for: error)
            phase = .choosing
        }
    }

    // MARK: - Asked (Patient)

    private func asked(_ id: RequestID) -> some View {
        let p = themed.palette
        return ScrollView {
            VStack(spacing: Tokens.Spacing.l) {
                RecordArt(side: 140).accessibilityHidden(true).padding(.top, Tokens.Spacing.xl)
                Text("We'll keep looking").magpieDisplay(.title2)
                Text(recording.title + " · " + recording.artist).font(.subheadline).foregroundStyle(p.ink2Color)
                    .multilineTextAlignment(.center)
                Text("This one might take a while. It can take a few hours. It shows up in Library › Requests, and in your library when it's home.")
                    .font(.body).multilineTextAlignment(.center)
                    .accessibilityIdentifier("try-asked")
                if let r = model.magpieRequest(id) {
                    Label(RequestCopy.status(r, context: model.waitContext), systemImage: RequestCopy.symbol(r))
                        .font(.footnote).foregroundStyle(p.accentInkColor)
                }
            }
            .padding(.horizontal, Tokens.Spacing.largeTitleMargin)
            .frame(maxWidth: .infinity)
        }
        .background(p.bgColor)
    }
}
