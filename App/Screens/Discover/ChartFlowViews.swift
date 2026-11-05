import AurralKit
import DesignSystem
import MagpieCore
import SwiftUI

/// Round 15 C2 (owner item 5, D134; fix round I1, M2, M3): a chart's flow on Trending. Without one: **Create flow…** (a
/// sheet with "Songs: N"); with one: **Edit flow** (Songs: N, Refresh now, Remove flow), its N, and its state: Setting
/// up… while the server makes it (Edit flow waits until it has), then A4's (Downloading 3/10, In your flows; songs that
/// couldn't download with Retry), or **Couldn't create the flow** with Retry. A flow lost here but on the server is
/// taken back. Hidden without accessFlow or songs; without a download source it explains first.
struct ChartFlowControl: View {
    @Environment(AppModel.self) private var model
    let page: ChartPage
    @State private var editing = false
    @State private var explaining = false
    @State private var phase: ChartFlowPhase?
    @State private var retrying = false
    @State private var message: String?
    private let themed = Themed()

    private var flow: ChartFlow? { model.chartFlow(for: page.chart) }

    private var label: (text: String, symbol: String)? {
        switch phase {
        case .settingUp?: (DiscoverPagesCopy.settingUp, AddFlowPhase.preparing.symbol)
        case .couldntCreate?: (DiscoverPagesCopy.couldntCreateFlow, DiscoverPagesCopy.couldntDownloadSymbol)
        case .live(let p)? where p != .ready && p != .hidden: p.label.map { ($0, p.symbol) }
        default: nil
        }
    }

    var body: some View {
        if model.aurralCanAddFlow, !page.songs.isEmpty {
            VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
                if let flow {
                    if phase == .couldntCreate {
                        HStack(spacing: Tokens.Spacing.s) {
                            Label(DiscoverPagesCopy.couldntCreateFlow, systemImage: DiscoverPagesCopy.couldntDownloadSymbol)
                                .font(.footnote.weight(.semibold))
                                .accessibilityIdentifier("chart-flow-state")
                            Button(DiscoverPagesCopy.retry) { Task { await retry() } }
                                .font(.footnote.weight(.semibold))
                                .disabled(retrying)
                                .accessibilityIdentifier("chart-flow-retry")
                        }
                    } else {
                        HStack(spacing: Tokens.Spacing.s) {
                            CapsuleButton(DiscoverPagesCopy.editFlow, symbol: "slider.horizontal.3") { editing = true }
                                .disabled(!flow.confirmed)   // M2: not while the server is still making it
                                .accessibilityIdentifier("chart-flow-edit")
                            Text(DiscoverPagesCopy.flowSongs(flow.count))
                                .font(.footnote).foregroundStyle(themed.palette.ink2Color)
                                .accessibilityIdentifier("chart-flow-count-label")
                        }
                        if let label {
                            Label(label.text, systemImage: label.symbol)
                                .font(.footnote.weight(.semibold))
                                .accessibilityIdentifier("chart-flow-state")
                        }
                        if flow.confirmed {
                            if case .live(let live)? = phase { SyncedFailures(playlistId: flow.playlistId, phase: live) }
                        }
                    }
                } else {
                    CapsuleButton(DiscoverPagesCopy.createFlow, symbol: "plus.circle") {
                        if model.aurralHasDownloader == false { explaining = true } else { editing = true }
                    }
                    .accessibilityIdentifier("chart-flow-create-open")
                }
            }
            .sheet(isPresented: $editing) {
                ChartFlowSheet(page: page, flow: flow)
            }
            .alert(DiscoverPagesCopy.noDownloaderTitle, isPresented: $explaining) {
                Button(DiscoverPagesCopy.createFlow) { editing = true }
                Button(DiscoverPagesCopy.cancel, role: .cancel) {}
            } message: {
                Text(DiscoverPagesCopy.noDownloader)
            }
            .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK", role: .cancel) {}
            }
            .task(id: "\(page.chart.key)#\(flow?.playlistId ?? "")#\(flow?.confirmed == true)") {
                await model.followChartFlow(page, every: .seconds(flow?.confirmed == true ? 30 : 5)) { phase = $0 }
            }
        }
    }

    private func retry() async {
        retrying = true
        defer { retrying = false }
        do { _ = try await model.retryChartFlow(page) } catch { message = DiscoverCopy.message(for: error) }
    }
}

/// Create flow / Edit flow: "Songs: N" (a stepper, with quick picks Top 10, 20, 25, 50, 100 up to the chart's length),
/// then Create, or Save, Refresh now and Remove flow. Every send is the owner's tap.
struct ChartFlowSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let page: ChartPage
    let flow: ChartFlow?
    @State private var count: Int
    @State private var working = false
    @State private var confirmingRemove = false
    @State private var message: String?

    init(page: ChartPage, flow: ChartFlow?) {
        self.page = page
        self.flow = flow
        let most = max(1, min(page.songs.count, ChartFlowPlan.maxSongs))
        _count = State(initialValue: min(most, flow?.count ?? ChartFlowPlan.defaultCount(chartLength: page.songs.count)))
    }

    private var most: Int { max(1, min(page.songs.count, ChartFlowPlan.maxSongs)) }
    private var chartName: String { model.chartTitle(page.chart) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper(value: $count, in: 1...most) {
                        Text(DiscoverPagesCopy.flowSongs(count)).monospacedDigit()
                    }
                    .accessibilityIdentifier("chart-flow-count")
                    let presets = ChartFlowPlan.presets(chartLength: page.songs.count)
                    if presets.count > 1 {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: Tokens.Spacing.s) {
                                ForEach(presets, id: \.self) { n in
                                    Button(DiscoverPagesCopy.topCount(n)) { count = n }
                                        .buttonStyle(.bordered)
                                        .tint(n == count ? .accentColor : .secondary)
                                        .accessibilityAddTraits(n == count ? .isSelected : [])
                                        .accessibilityIdentifier("chart-flow-preset-\(n)")
                                }
                            }
                        }
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                        Text(DiscoverPagesCopy.flowNote(chartName, count))
                        Text(DiscoverPagesCopy.editFlowNote)   // M7: Not for me songs are skipped; I2: what goes
                    }
                }
                if let flow {
                    Section {
                        Button(DiscoverPagesCopy.refreshNow) { Task { await run { try await model.refreshChartFlow(page.chart) } } }
                            .accessibilityIdentifier("chart-flow-refresh")
                        Button(DiscoverPagesCopy.removeFlow, role: .destructive) { confirmingRemove = true }
                            .accessibilityIdentifier("chart-flow-remove")
                    } footer: {
                        Text(DiscoverPagesCopy.flowUpdated(flow.refreshedAt))
                    }
                }
            }
            .disabled(working)
            .navigationTitle(flow == nil ? DiscoverPagesCopy.createFlowTitle : DiscoverPagesCopy.editFlow)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(DiscoverPagesCopy.cancel) { dismiss() }
                        .accessibilityIdentifier("chart-flow-cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    if working {
                        ProgressView()
                    } else if flow == nil {
                        Button(DiscoverPagesCopy.create) { Task { await run { try await model.createChartFlow(page, count: count) } } }
                            .accessibilityIdentifier("chart-flow-create")
                    } else {
                        Button(DiscoverPagesCopy.save) { Task { await run { try await model.resizeChartFlow(page, count: count) } } }
                            .disabled(count == flow?.count)
                            .accessibilityIdentifier("chart-flow-save")
                    }
                }
            }
            .confirmationDialog(DiscoverPagesCopy.removeFlowQuestion, isPresented: $confirmingRemove, titleVisibility: .visible) {
                Button(DiscoverPagesCopy.removeFlow, role: .destructive) {
                    Task { await run { try await model.removeChartFlow(page.chart) } }
                }
                .accessibilityIdentifier("chart-flow-remove-confirm")
            } message: {
                Text(DiscoverPagesCopy.removeFlowNote)
            }
            .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK", role: .cancel) {}
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// Sends one change; closes on success, says why otherwise.
    private func run(_ change: @escaping () async throws -> Any) async {
        working = true
        defer { working = false }
        do {
            _ = try await change()
            dismiss()
        } catch {
            message = DiscoverCopy.message(for: error)
        }
    }
}

/// Trending's chart picker (owner item 5b, D132): Worldwide, every country with a chart (searchable, names in the
/// phone's language) and the genre charts. The default is marked.
struct ChartPickerSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let shown: TrendingChart?
    let defaultChart: TrendingChart?
    let pick: (TrendingChart) -> Void
    @State private var query = ""

    var body: some View {
        let charts = model.trendingCharts
        let countries = charts.countries.filter { query.isEmpty || $0.name.localizedStandardContains(query) }
        let genres = charts.genres.filter { query.isEmpty || $0.name.localizedStandardContains(query) }
        NavigationStack {
            List {
                if charts.worldwide, query.isEmpty || DiscoverPagesCopy.worldwide.localizedStandardContains(query) {
                    Section { row(.worldwide, DiscoverPagesCopy.worldwide) }
                }
                if !genres.isEmpty {
                    Section(DiscoverPagesCopy.genres) {
                        ForEach(genres, id: \.id) { row(.genre($0.id), $0.name) }
                    }
                }
                if !countries.isEmpty {
                    Section(DiscoverPagesCopy.countries) {
                        ForEach(countries, id: \.code) { row(.country($0.code), $0.name) }
                    }
                }
            }
            .searchable(text: $query)
            .navigationTitle(DiscoverPagesCopy.charts)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(DiscoverPagesCopy.cancel) { dismiss() } }
            }
        }
    }

    private func row(_ chart: TrendingChart, _ name: String) -> some View {
        Button {
            pick(chart)
            dismiss()
        } label: {
            HStack {
                Text(name)
                if chart == defaultChart {
                    Text(DiscoverPagesCopy.defaultChart).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
                Spacer()
                if chart == shown { Image(systemName: "checkmark").accessibilityHidden(true) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(chart == shown ? .isSelected : [])
        .accessibilityIdentifier("chart-option-\(chart.key)")
    }
}
