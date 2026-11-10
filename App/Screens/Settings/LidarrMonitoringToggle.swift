import SwiftUI

/// Round 24 (owner, 2026-11-08, Q10): Settings › Lidarr "Let Magpie change what Lidarr monitors for my artists", off by
/// default for each Lidarr. Off, the artist pages show no "Change what's monitored" or "Clean up unmatched songs", and the
/// gate refuses those writes whatever asks (D243). It needs "Allow Magpie to change your library" on first.
struct LidarrMonitoringToggle: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Section {
            Toggle(MonitoringCopy.toggle, isOn: Binding(
                get: { model.monitoringChangesAllowed },
                set: { on in Task { await model.setMonitoringChangesAllowed(on) } }))
                .disabled(!model.changesAllowed)
                .accessibilityIdentifier("settings-monitoring-changes")
        } footer: {
            Text(model.changesAllowed ? MonitoringCopy.toggleFooter : MonitoringCopy.toggleNeedsChanges)
        }
    }
}
