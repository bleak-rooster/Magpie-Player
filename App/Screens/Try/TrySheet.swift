import DesignSystem
import MagpieCore
import Requests
import Search
import SwiftUI

/// Try on a song that's not in the library: into Finds when they're set up (Task 6.2a), else straight into
/// the library (fallback mode, M5, B8). Standard tier: "Try it", then the wait screen.
/// Patient tier (D8): "Ask for it", a confirmation, and no spinning wait screen; it shows up in Requests.
/// When Try isn't possible yet, says why calmly and opens Settings.
struct TrySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let recording: ExternalRecording
    /// R19 "Try this album": the album and its release group (the target); `recording` is its first track.
    var album: NotYetAlbum? = nil
    var albumGroup: MBID? = nil
    /// R19: a track of an outside album; a live request for that album opens instead of a second Try (R20).
    var releaseGroup: MBID? = nil

    init(recording: ExternalRecording) { self.recording = recording }

    init(target: TryTarget) {
        recording = target.recording
        album = target.album
        albumGroup = target.albumGroup
        releaseGroup = target.releaseGroup
    }

    static let tryAlbumTitle = "Try this album"

    enum Phase: Equatable {
        case choosing
        case working
        case waiting(RequestID)
        case asked(RequestID)
    }

    /// R17: a song already on its way (or Ready) opens its request instead of a second Try. Nil: Try as usual.
    /// - Parameters:
    ///   - album: Try this album: only a request bringing in that release group counts; a single-song request for its
    ///     first track never stands for the album (review I1).
    ///   - releaseGroup: a track of an outside album: its own request, else its album's (R20).
    static func existingPhase(for recording: ExternalRecording, album: MBID? = nil, releaseGroup: MBID? = nil,
                              in requests: [MagpieRequest]) -> Phase? {
        let found = album.map { RequestLinks.request(releaseGroup: $0, in: requests) }
            ?? (RequestLinks.request(for: recording, in: requests) ?? RequestLinks.request(releaseGroup: releaseGroup, in: requests))
        guard let live = found else { return nil }
        return live.tier.asksInsteadOfWaiting ? .asked(live.id) : .waiting(live.id)
    }

    @State private var phase = Phase.choosing
    @State private var error: String?
    @State private var showsSettings = false
    /// R16: the song's cover from outside while the sheet is open (R15 rules: memory only, fetched again next time).
    @State private var outsideArt: OutsideArtLoader?
    private let themed = Themed()

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .choosing, .working: choosing
                case .waiting(let id): RequestDetailView(requestId: id, footnote: TryCopy.keepBrowsing)   // R20
                case .asked(let id): asked(id)
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    // R20: Done, never "Leave" (which reads as abandon); the footnote says it keeps coming.
                    Button(Self.closeTitle) { dismiss() }
                        .accessibilityHint(isWaiting ? "It keeps coming. Find it in Library, Requests." : "")
                        .accessibilityIdentifier("try-done")
                }
            }
        }
        .sheet(isPresented: $showsSettings) { SettingsView(opening: [.requests]) }   // T21b: every reason Try names is on New music
        .onAppear {
            // R17: a song already on its way opens its request, never a second Try.
            if phase == .choosing, let live = Self.existingPhase(for: recording, album: albumGroup, releaseGroup: releaseGroup,
                                                                 in: model.requests) { phase = live }
        }
        .task { if outsideArt == nil { outsideArt = model.makeOutsideArt() } }   // R16
        .onDisappear { outsideArt?.reset() }
    }

    /// The record, with the song's cover as its label once it's here (R16); Classic draws it as a square with the
    /// not-yet badge (D3).
    private var record: some View {
        let cover = model.requests.last { $0.recording.recordingMBID != nil && $0.recording.recordingMBID == recording.recordingMBID }?.cover
            ?? MagpieRequestCover(songId: nil, outside: .cover(releaseGroup: albumGroup, release: recording.releaseMBID),
                                  artist: recording.artistMBID.map(OutsideArtKey.artist))
        return RequestArtwork(cover: cover, loader: outsideArt, side: 140) { art in
            RecordArt(image: art, side: 140).recordBadge(RowState.notYet.statusSymbol, size: 22)
        }
        .accessibilityHidden(true).padding(.top, Tokens.Spacing.xl)
    }

    static let closeTitle = "Done"

    private var isWaiting: Bool { if case .waiting = phase { true } else { false } }

    // MARK: - Choosing

    private var choosing: some View {
        let p = themed.palette
        let availability = model.tryAvailability
        return ScrollView {
            VStack(spacing: Tokens.Spacing.l) {
                record
                VStack(spacing: Tokens.Spacing.xs) {
                    Text(album?.title ?? recording.title).magpieDisplay(.title2).multilineTextAlignment(.center)
                    Text(details).font(.subheadline).foregroundStyle(p.ink2Color).multilineTextAlignment(.center)
                    StatusLine(.notYet)
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
                            Text(tier.asksInsteadOfWaiting ? RequestCopy.askForIt : album != nil ? Self.tryAlbumTitle : "Try it")
                        }
                        .frame(maxWidth: .infinity, minHeight: Tokens.minHitSize)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(phase == .working)
                    .accessibilityIdentifier("try-start")
                case .offline:   // Task 14: nothing to set; it works again once back online
                    Label(availability.message ?? "", systemImage: "wifi.slash").font(.body)
                        .accessibilityIdentifier("try-offline")
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
        if let album {
            return ([album.kind ?? "Album", album.artist] + [album.year.map(String.init)].compactMap { $0 })
                .joined(separator: " · ")
        }
        var parts = [recording.artist]
        if let album = recording.releaseTitle, !album.isEmpty { parts.append(album) }
        if let d = recording.duration, d > 0 { parts.append(DurationText.clock(d)) }
        return parts.joined(separator: " · ")
    }

    private func start(_ tier: Tier) async {
        error = nil
        phase = .working
        do {
            let id: RequestID
            if let albumGroup {
                id = try await model.tryAlbum(recording, releaseGroup: albumGroup)
            } else if releaseGroup != nil {
                id = try await model.tryTrack(recording, releaseGroup: releaseGroup)
            } else {
                id = try await model.tryRecording(recording)
            }
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
                record
                Text("We'll keep looking").magpieDisplay(.title2)
                Text((album?.title ?? recording.title) + " · " + recording.artist).font(.subheadline).foregroundStyle(p.ink2Color)
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
