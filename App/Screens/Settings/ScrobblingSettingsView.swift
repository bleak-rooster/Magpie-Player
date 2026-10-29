import ListenBrainzKit
import MagpieCore
import SwiftUI

/// Settings › Scrobbling (spec §7): Count plays, where plays go (Navidrome and/or ListenBrainz directly), when a
/// play counts, and the ListenBrainz token.
struct ScrobblingSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var token = ""
    @State private var tokenError: String?
    @State private var checkingToken = false

    static let countPlaysFooter = "When on, songs you play are added to your listening history. Turn off while you're trying things out."
    static let needsTokenFooter = "Add your ListenBrainz token below to send plays there directly."
    static let doubleCountNote = "If your Navidrome also sends plays to ListenBrainz, they'll be counted twice."
    static let rejectedCopy = "ListenBrainz didn't accept your token. Save a new one to send plays there again."

    private func binding<V>(_ keyPath: WritableKeyPath<ScrobblePreferences, V>) -> Binding<V> {
        Binding(get: { model.preferences.scrobbling[keyPath: keyPath] },
                set: { value in model.updatePreferences { $0.scrobbling[keyPath: keyPath] = value } })
    }

    var body: some View {
        Form {
            Section {
                Toggle("Count plays", isOn: Binding(get: { model.countPlays }, set: { model.setCountPlays($0) }))
                    .accessibilityIdentifier("settings-count-plays")
            } footer: {
                Text(Self.countPlaysFooter)
            }
            Group {
                destinations
                threshold
            }
            .disabled(!model.countPlays)
            listenBrainzToken
        }
        .navigationTitle("Scrobbling")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Where plays go

    /// Without a token nothing goes to ListenBrainz, so its switch reads Off (and is disabled) whatever is stored.
    static func listenBrainzShowsOn(_ p: ScrobblePreferences, hasToken: Bool) -> Bool { p.viaListenBrainz && hasToken }

    /// The footer under the destinations: how to turn ListenBrainz on, or the double-count note when both are on.
    static func destinationsFooter(_ p: ScrobblePreferences, hasToken: Bool) -> String? {
        if !hasToken { return needsTokenFooter }
        return p.viaNavidrome && p.viaListenBrainz ? doubleCountNote : nil
    }

    @ViewBuilder private var destinations: some View {
        let p = model.preferences.scrobbling, hasToken = model.hasListenBrainzToken
        Section {
            Toggle("Send plays through Navidrome", isOn: binding(\.viaNavidrome))
                .accessibilityIdentifier("scrobbling-via-navidrome")
            Toggle("Send plays directly to ListenBrainz", isOn: Binding(
                get: { Self.listenBrainzShowsOn(model.preferences.scrobbling, hasToken: model.hasListenBrainzToken) },
                set: { on in model.updatePreferences { $0.scrobbling.viaListenBrainz = on } }))
                .disabled(!hasToken)
                .accessibilityIdentifier("scrobbling-via-listenbrainz")
        } footer: {
            if let footer = Self.destinationsFooter(p, hasToken: hasToken) {
                Text(footer).accessibilityIdentifier("scrobbling-destinations-footer")
            }
        }
    }

    // MARK: - When a play counts

    @ViewBuilder private var threshold: some View {
        let rule = model.preferences.scrobbling.rule
        Section {
            VStack(alignment: .leading) {
                LabeledContent("Counts as played after", value: "\(rule.percent)%")
                Slider(value: Binding(get: { Double(rule.percent) },
                                      set: { value in model.updatePreferences { $0.scrobbling.rule.percent = Int(value) } }),
                       in: 10...90, step: 5) {
                    Text("Counts as played after")
                } minimumValueLabel: {
                    Text("10%")
                } maximumValueLabel: {
                    Text("90%")
                }
                .accessibilityValue("\(rule.percent)%")
                .accessibilityIdentifier("scrobbling-percent")
            }
            Picker("or after", selection: binding(\.rule.minutes)) {
                ForEach(1...10, id: \.self) { Text("\($0) min").tag(Optional($0)) }
                Text("Never").tag(Int?.none)
            }
            .accessibilityIdentifier("scrobbling-minutes")
        } footer: {
            Text("Whichever comes first. Songs under 30 seconds never count.")
        }
    }

    // MARK: - ListenBrainz token

    @ViewBuilder private var listenBrainzToken: some View {
        Section {
            if model.hasListenBrainzToken {
                LabeledContent("ListenBrainz token", value: "Saved")
                if model.listenBrainzRejected {
                    Label(Self.rejectedCopy, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .accessibilityIdentifier("scrobbling-token-rejected")
                }
                Button("Remove token", role: .destructive) { try? model.setListenBrainzToken(nil) }
            } else {
                SecureField("ListenBrainz token (optional)", text: $token)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("settings-lb-token")
                Button(checkingToken ? "Checking…" : "Save token") {
                    // B-M8: checked with ListenBrainz before it is saved.
                    checkingToken = true
                    Task {
                        do {
                            try await model.saveListenBrainzToken(token)
                            token = ""
                            tokenError = nil
                        } catch let error as ListenBrainzTokenError {
                            tokenError = error.message
                        } catch {
                            tokenError = "Couldn't save the token. Try again."
                        }
                        checkingToken = false
                    }
                }
                .disabled(checkingToken || token.trimmingCharacters(in: .whitespaces).isEmpty)
                if let tokenError { Text(tokenError).font(.footnote) }
            }
        } header: {
            Text("ListenBrainz")
        } footer: {
            Text("Optional. Kept in your Keychain and only sent to ListenBrainz.")
        }
    }
}
