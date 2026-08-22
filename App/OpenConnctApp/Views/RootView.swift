import SwiftUI

// MARK: - RootView
//
// Navigation model: the window *is* the mixer. A microphone's settings open on
// top of it and are dismissed again.
//
// This replaced a permanent two-pane split, and the reason is worth recording
// because the split looked reasonable on paper. With a detail pane pinned to
// the right there is no such thing as "no microphone selected" — the pane has
// to show something, so one channel was always force-selected on launch. The
// user never asked for that microphone and could not put it away, so the
// window carried a settings screen for a channel nobody was editing, at all
// times, taking more than half the width.
//
// It was also what made the window unshrinkable in practice. Two panes with
// their own minimum widths sum to a floor of several hundred points before the
// mixer has drawn a single strip, so the window could never be small even when
// the user only wanted to see two faders.
//
// Presented as a sheet, the settings exist exactly when someone opened them,
// the mixer keeps the whole window, and the window's minimum size is the
// mixer's own — which is small.

/// Sheet presentation needs an `Identifiable` subject, and a device UID is
/// already unique. Wrapping it also makes "which microphone is being edited"
/// a single piece of state rather than a selection plus a visibility flag that
/// can disagree with each other.
private struct EditingMic: Identifiable {
    let id: String
}

struct RootView: View {
    @EnvironmentObject var store: ParameterStore
    @State private var editing: EditingMic?
    @StateObject private var driverInstaller = DriverInstaller()

    var body: some View {
        VStack(spacing: 0) {
            // Absent from the tree entirely unless the driver needs installing
            // or updating, so in the normal case it costs nothing.
            DriverBanner(installer: driverInstaller)

            // Above the mixer, not inside it: what it shows — whether the app
            // is working and what is leaving it — is true for the whole
            // window, not for one part of it.
            HeaderBar(
                store: store,
                diagnosticsSource: store.meterHub.diagnostics,
                masterSource: store.meterHub.master)
            Divider().background(Theme.border)

            MixerView(
                store: store,
                selectedUID: editing?.id,
                onSelectChannel: { editing = EditingMic(id: $0) })
        }
        .background(Theme.bg)
        .sheet(item: $editing) { target in
            if let settings = store.channels.first(where: { $0.deviceUID == target.id }) {
                MicDetailView(
                    settings: settings,
                    connection: store.meterHub.connection(for: target.id),
                    meterSource: store.meterHub.meterSource(for: target.id),
                    store: store,
                    onClose: { editing = nil })
            }
        }
        .onChange(of: store.channels) { channels in
            // A microphone can be unplugged while its settings are open. Close
            // them rather than leaving a sheet describing a device that is no
            // longer there.
            if let target = editing, !channels.contains(where: { $0.deviceUID == target.id }) {
                editing = nil
            }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            // The driver can also be installed, updated or removed from
            // outside the app — by the .pkg, by one of the scripts, or by
            // hand. Re-reading on activation means the banner reflects the
            // disk rather than what was true when the app launched.
            driverInstaller.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: .ocSinkAvailabilityChanged)
        ) { _ in
            // The other way round: the driver can vanish while the app is
            // frontmost and never loses focus, in which case the mixer would
            // say "No device" with no explanation and no way to fix it.
            driverInstaller.refresh()
        }
    }
}
