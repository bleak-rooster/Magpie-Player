import DesignSystem
import SwiftUI

/// Sign in to the music server: one or more addresses (home first, then away), username, password.
struct ConnectView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.magpieTheme) private var theme
    @Environment(\.openURL) private var openURL
    private let themed = Themed()

    @State private var addresses: [String] = [""]
    @State private var username = ""
    @State private var password = ""
    @State private var isConnecting = false
    @State private var error: String?
    /// T3: the error is the Local Network one; offer Open Settings.
    @State private var offersSettings = false
    @State private var askingLocalNetwork = false
    /// Plain-http public addresses waiting for the owner's yes (security H2).
    @State private var unencrypted: [URL] = []
    @FocusState private var focus: Field?

    private enum Field: Hashable { case address(Int), username, password }

    var body: some View {
        let p = themed.palette
        NavigationStack {
            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
                    Text("Your music server")
                        .magpieDisplay(.largeTitle)
                        .accessibilityAddTraits(.isHeader)
                    Text("Where your songs live. We'll reach it at home and when you're out.")
                        .font(.body).foregroundStyle(p.ink2Color)
                    Text("Your music server (Navidrome)")
                        .font(.footnote).foregroundStyle(p.ink2Color)

                    groupHeader("Addresses").padding(.top, 18)
                    group {
                        ForEach(addresses.indices, id: \.self) { i in
                            addressRow(i)
                            Divider().overlay(p.sepColor)
                        }
                        Button {
                            addresses.append("")
                            focus = .address(addresses.count - 1)
                        } label: {
                            Label("Add another address", systemImage: "plus.circle.fill")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(p.accentInkColor)
                                .frame(maxWidth: .infinity, minHeight: Tokens.minHitSize, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, Tokens.Spacing.l)
                    }
                    Text("We switch between these on our own when you leave the house.")
                        .font(.footnote).foregroundStyle(p.ink2Color)
                        .padding(.horizontal, Tokens.Spacing.l)
                    Label(ConnectErrorCopy.httpsAdvice, systemImage: "lock.fill")
                        .font(.footnote).foregroundStyle(p.ink2Color)
                        .padding(.horizontal, Tokens.Spacing.l)
                        .accessibilityIdentifier("connect-https-advice")

                    group {
                        field("Username") {
                            TextField("Username", text: $username)
                                .textContentType(.username)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .focused($focus, equals: .username)
                                .submitLabel(.next)
                                .onSubmit { focus = .password }
                                .accessibilityIdentifier("connect-username")
                        }
                        Divider().overlay(p.sepColor)
                        field("Password") {
                            SecureField("Password", text: $password)
                                .textContentType(.password)
                                .focused($focus, equals: .password)
                                .submitLabel(.go)
                                .onSubmit { Task { await connect() } }
                                .accessibilityIdentifier("connect-password")
                        }
                    }
                    .padding(.top, 18)

                    if let error {
                        Label(error, systemImage: offersSettings ? "network.slash" : "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(p.inkColor)
                            .padding(Tokens.Spacing.l)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(p.surfaceColor, in: RoundedRectangle(cornerRadius: Tokens.Radius.card / 2))
                            .padding(.top, Tokens.Spacing.m)
                            .accessibilityIdentifier("connect-error")
                            .id("connect-error")
                    }
                    localNetworkButtons
                }
                .padding(.horizontal, Tokens.Spacing.largeTitleMargin)
                .padding(.top, Tokens.Spacing.xxl)
                .padding(.bottom, 120)
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom) { continueButton }
            .onChange(of: error) { _, new in
                if new != nil { withAnimation { proxy.scrollTo("connect-error", anchor: .center) } }
            }
            }
            .foregroundStyle(p.inkColor)
            .magpieScreen()
        }
        .onChange(of: error) { _, new in
            if let new { AccessibilityNotification.Announcement(new).post() }
        }
        // T2 fix C1: a saved session whose address has no consent yet: ask, and fill in the form either way.
        .onChange(of: model.savedSessionAwaitingConsent, initial: true) { _, pending in
            guard let pending else { return }
            addresses = pending.bases.map(\.absoluteString)
            username = pending.username
            error = ConnectErrorCopy.savedSessionNeedsConsent
        }
        .alert(ConnectErrorCopy.plainHTTPTitle, isPresented: Binding(
            get: { !(model.savedSessionAwaitingConsent?.unencrypted.isEmpty ?? true) },
            set: { _ in })   // only its buttons close it, and each says what happens
        ) {
            Button(ConnectErrorCopy.plainHTTPConfirm, role: .destructive) { model.allowSavedSession() }
                .accessibilityIdentifier("connect-saved-plain-http-confirm")
            Button("Cancel", role: .cancel) { model.declineSavedSession() }
        } message: {
            Text(ConnectErrorCopy.plainHTTPMessage + "\n\n"
                 + (model.savedSessionAwaitingConsent?.unencrypted ?? []).map { $0.host ?? $0.absoluteString }.joined(separator: ", "))
        }
        .alert(ConnectErrorCopy.plainHTTPTitle, isPresented: Binding(
            get: { !unencrypted.isEmpty }, set: { if !$0 { unencrypted = [] } })
        ) {
            Button(ConnectErrorCopy.plainHTTPConfirm, role: .destructive) {
                model.allowPlainHTTP(unencrypted)
                unencrypted = []
                Task { await connect() }
            }
            .accessibilityIdentifier("connect-plain-http-confirm")
            Button("Cancel", role: .cancel) { unencrypted = [] }
        } message: {
            Text(ConnectErrorCopy.plainHTTPMessage + "\n\n" + unencrypted.map { $0.host ?? $0.absoluteString }.joined(separator: ", "))
        }
    }

    /// T3: ask for Local Network access again (until it is known to be on), and the way to Settings when it is off.
    @ViewBuilder private var localNetworkButtons: some View {
        let p = themed.palette
        if offersSettings {
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            } label: {
                Label("Open Settings", systemImage: "gear")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(p.accentInkColor)
                    .frame(maxWidth: .infinity, minHeight: Tokens.minHitSize, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, Tokens.Spacing.l)
            .accessibilityIdentifier("connect-open-settings")
        }
        if model.localNetwork.state != .granted {
            Button {
                Task {
                    askingLocalNetwork = true
                    defer { askingLocalNetwork = false }
                    await model.localNetwork.request()
                }
            } label: {
                HStack(spacing: Tokens.Spacing.s) {
                    Label("Allow local network access", systemImage: "network")
                    if askingLocalNetwork { ProgressView() }
                }
                .font(.body.weight(.semibold))
                .foregroundStyle(p.accentInkColor)
                .frame(maxWidth: .infinity, minHeight: Tokens.minHitSize, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(askingLocalNetwork)
            .padding(.horizontal, Tokens.Spacing.l)
            .accessibilityIdentifier("connect-allow-local-network")
        }
    }

    private var continueButton: some View {
        let p = themed.palette
        return Button {
            Task { await connect() }
        } label: {
            HStack(spacing: Tokens.Spacing.s) {
                if isConnecting { ProgressView().tint(p.onAccentColor) }
                Text(isConnecting ? "Connecting…" : "Continue").font(.headline)
            }
            .frame(maxWidth: .infinity, minHeight: 50)
            .foregroundStyle(p.onAccentColor)
            .background(p.accentColor, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isConnecting)
        .padding(.horizontal, Tokens.Spacing.largeTitleMargin)
        .padding(.bottom, Tokens.Spacing.s)
        .accessibilityIdentifier("connect-continue")
    }

    private func addressRow(_ i: Int) -> some View {
        let p = themed.palette
        let label = i == 0 ? "Home" : (i == 1 ? "Away" : "Address \(i + 1)")
        return HStack(spacing: Tokens.Spacing.m) {
            Image(systemName: i == 0 ? "house.fill" : "globe")
                .foregroundStyle(p.accentInkColor)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.subheadline.weight(.semibold))
                TextField(i == 0 ? "http://192.168.1.20:4533" : "https://music.example.com", text: $addresses[i])
                    .font(.callout)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focus, equals: .address(i))
                    .submitLabel(.next)
                    .onSubmit { focus = i + 1 < addresses.count ? .address(i + 1) : .username }
                    .accessibilityLabel("\(label) address")
                    .accessibilityIdentifier("connect-address-\(i)")
            }
            if addresses.count > 1 {
                Button {
                    addresses.remove(at: i)
                } label: {
                    Image(systemName: "minus.circle.fill").foregroundStyle(p.ink2Color)
                        .frame(width: Tokens.minHitSize, height: Tokens.minHitSize)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(label) address")
            }
        }
        .padding(.horizontal, Tokens.Spacing.l)
        .padding(.vertical, Tokens.Spacing.s)
    }

    private func groupHeader(_ text: String) -> some View {
        Text(text).font(.footnote.weight(.semibold)).foregroundStyle(themed.palette.ink2Color)
            .textCase(.uppercase)
            .padding(.horizontal, Tokens.Spacing.l)
            .accessibilityAddTraits(.isHeader)
    }

    private func group<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .background(themed.palette.surfaceColor, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func field<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack {
            Text(label).font(.body).frame(width: 96, alignment: .leading).accessibilityHidden(true)
            content()
        }
        .padding(.horizontal, Tokens.Spacing.l)
        .frame(minHeight: Tokens.minHitSize + 4)
    }

    private func connect() async {
        guard !isConnecting else { return }
        error = nil
        offersSettings = false
        focus = nil
        let typed = addresses.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        var urls: [URL] = []
        for text in typed {
            switch ServerAddress.check(text) {
            case .url(let url):
                urls.append(url)
            case .containsCredentials:
                error = ConnectErrorCopy.credentialsInAddress
                return
            case .invalid:
                error = ConnectErrorCopy.message(for: SignInError.invalidAddress(text))
                return
            }
        }
        guard !username.isEmpty else {
            error = "Enter your username."
            focus = .username
            return
        }
        isConnecting = true
        defer { isConnecting = false }
        do {
            try await model.signIn(urls: urls, username: username, password: password)
        } catch let consent as PlainHTTPConsentRequired {
            unencrypted = consent.urls
        } catch {
            offersSettings = ConnectErrorCopy.offersOpenSettings(for: error)
            self.error = ConnectErrorCopy.message(for: error)
        }
    }
}
