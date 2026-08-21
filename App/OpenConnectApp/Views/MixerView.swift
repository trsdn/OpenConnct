import SwiftUI
import AppKit

// MARK: - DiagnosticsBar
//
// Two audiences, two levels. Day to day the user only needs to know whether the
// thing is working, so the bar shows one plain-language status and nothing else.
// The counters behind it (xruns, drift in ppm, ring fill) are engineering
// telemetry: useful when diagnosing a fault, meaningless otherwise, and actively
// harmful in the default view because they change several times a second and
// shift the layout around them.
//
// Every numeric row is monospaced-digit and fixed-width so nothing reflows as
// values change.

private struct DiagnosticsBar: View {
    @ObservedObject var source: DiagnosticsSource
    @ObservedObject var store: ParameterStore
    @State private var showDetails = false
    @State private var showDevices = false

    private var diagnostics: EngineDiagnostics { source.value }

    private enum Status {
        case ready, noDriver, stopped, glitching

        var text: String {
            switch self {
            case .ready: return "Ready"
            case .noDriver: return "Virtual device not found"
            case .stopped: return "Engine stopped"
            case .glitching: return "Audio dropouts detected"
            }
        }

        var colour: Color {
            switch self {
            case .ready: return Theme.meterGreen
            case .noDriver, .glitching: return Theme.meterAmber
            case .stopped: return Theme.meterRed
            }
        }
    }

    private var status: Status {
        if !diagnostics.running { return .stopped }
        if !diagnostics.sinkAvailable { return .noDriver }
        if diagnostics.underruns > 0 || diagnostics.overruns > 0 { return .glitching }
        return .ready
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(status.colour)
                .frame(width: 6, height: 6)

            Text(status.text)
                .font(Theme.captionFont)
                .foregroundColor(status == .ready ? Theme.textSecondary : status.colour)
                .fixedSize(horizontal: true, vertical: false)

            Spacer(minLength: 8)

            Button {
                showDevices = true
            } label: {
                Label("Inputs", systemImage: "slider.horizontal.3")
                    .font(Theme.captionFont)
                    .foregroundColor(Theme.textSecondary)
            }
            .buttonStyle(.plain)
            .help("Choose which inputs OpenConnect uses")

            Button {
                showDetails.toggle()
            } label: {
                Text("Details")
                    .font(Theme.captionFont)
                    .foregroundColor(Theme.textDisabled)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showDetails, arrowEdge: .bottom) {
                DiagnosticsDetail(diagnostics: diagnostics)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .frame(height: 24)
        .background(Theme.panel)
        .sheet(isPresented: $showDevices) {
            DeviceSelectionView(store: store)
        }
    }
}

// MARK: - DiagnosticsDetail

private struct DiagnosticsDetail: View {
    let diagnostics: EngineDiagnostics

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Diagnostics")
                .font(Theme.titleFont)
                .foregroundColor(Theme.textPrimary)

            row("Dropouts",
                value: "\(diagnostics.underruns + diagnostics.overruns)",
                help: "Times audio arrived too late or too early to be used. Should stay at 0.")

            row("Dropped edits",
                value: "\(diagnostics.droppedParameters)",
                help: "Control changes the audio thread could not accept in time. Should stay at 0.")

            if !diagnostics.perChannelRatioPPM.isEmpty {
                Divider().background(Theme.border)
                Text("Clock correction per microphone")
                    .font(Theme.labelFont)
                    .foregroundColor(Theme.textSecondary)
                Text("Each USB microphone runs on its own crystal, slightly off 48 kHz. "
                     + "This is how hard OpenConnect is stretching that mic to keep it in sync, "
                     + "in parts per million. Anything under 100 is normal.")
                    .font(Theme.captionFont)
                    .foregroundColor(Theme.textDisabled)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(diagnostics.perChannelRatioPPM.sorted(by: { $0.key < $1.key }), id: \.key) { uid, ppm in
                    HStack(spacing: 8) {
                        Text(diagnostics.perChannelName[uid] ?? uid)
                            .font(Theme.labelFont)
                            .foregroundColor(Theme.textSecondary)
                            .lineLimit(1)
                        Spacer(minLength: 12)
                        Text(String(format: "%+.0f ppm", ppm))
                            .font(Theme.valueFont)
                            .monospacedDigit()
                            .foregroundColor(abs(ppm) > 100 ? Theme.meterAmber : Theme.textPrimary)
                            .frame(width: 74, alignment: .trailing)
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 320, alignment: .leading)
    }

    @ViewBuilder
    private func row(_ label: String, value: String, help: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(label)
                    .font(Theme.labelFont)
                    .foregroundColor(Theme.textSecondary)
                Spacer(minLength: 12)
                Text(value)
                    .font(Theme.valueFont)
                    .monospacedDigit()
                    .foregroundColor(value == "0" ? Theme.textPrimary : Theme.meterAmber)
                    .frame(width: 74, alignment: .trailing)
            }
            Text(help)
                .font(Theme.captionFont)
                .foregroundColor(Theme.textDisabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Empty state

private struct EmptyMicView: View {
    /// Distinguishes "nothing is plugged in" from "you switched them all off",
    /// which look identical to the engine but need opposite advice.
    let hasAvailableDevices: Bool
    let onChooseInputs: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "mic.slash")
                .font(.system(size: 48))
                .foregroundColor(Theme.textDisabled)
            Text(hasAvailableDevices ? "No inputs selected" : "No microphones connected")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(Theme.textSecondary)
            Text(hasAvailableDevices
                 ? "Inputs are attached but none are switched on."
                 : "Connect a USB microphone and it will appear here.")
                .font(Theme.captionFont)
                .foregroundColor(Theme.textDisabled)
                .multilineTextAlignment(.center)
            if hasAvailableDevices {
                Button("Choose Inputs…", action: onChooseInputs)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Permission denied

private struct PermissionDeniedView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "mic.slash.fill")
                .font(.system(size: 48))
                .foregroundColor(Theme.meterRed)
            Text("Microphone Access Denied")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
            Text("OpenConnect needs microphone access to capture audio.\nPlease grant permission in System Settings.")
                .font(Theme.labelFont)
                .foregroundColor(Theme.textSecondary)
                .multilineTextAlignment(.center)
            Button("Open System Settings…") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .foregroundColor(.white)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - MixerView

struct MixerView: View {
    @ObservedObject var store: ParameterStore
    let selectedUID: String?
    let onSelectChannel: (String) -> Void

    @State private var showDevices = false

    var body: some View {
        VStack(spacing: 0) {
            DiagnosticsBar(source: store.meterHub.diagnostics, store: store)
            Divider().background(Theme.border)

            if store.microphonePermissionDenied {
                PermissionDeniedView()
            } else if store.channels.isEmpty {
                EmptyMicView(
                    hasAvailableDevices: !store.availableDevices.isEmpty,
                    onChooseInputs: { showDevices = true })
            } else {
                stripArea
            }
        }
        .background(Theme.bg)
        .sheet(isPresented: $showDevices) {
            DeviceSelectionView(store: store)
        }
    }

    @ViewBuilder
    private var stripArea: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 8) {
                ForEach(store.channels) { ch in
                    ChannelStripView(
                        settings: ch,
                        connection: store.meterHub.connection(for: ch.deviceUID),
                        meterSource: store.meterHub.meterSource(for: ch.deviceUID),
                        store: store,
                        isSelected: selectedUID == ch.deviceUID,
                        onSelect: { onSelectChannel(ch.deviceUID) }
                    )
                    .frame(height: 280)
                }
            }
            .padding(12)
        }
    }
}
