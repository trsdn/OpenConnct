import SwiftUI
import AppKit

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
        // Without this the mixer column keeps its natural height and gets
        // centred vertically, leaving black bands above and below it in any
        // window taller than the content.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                    // Deliberately a fixed height, not a flexible one. Meter
                    // redraw cost scales with the drawn area, and letting the
                    // strips stretch to 460pt took idle CPU from 6% to 16% on
                    // three channels. The black band the user saw came from
                    // the column not filling, not from the strips being short,
                    // so the strips stay put and the column absorbs the space.
                    .frame(height: 280)
                }

                // Last in the row, where the next microphone would go.
                AddChannelTile { showDevices = true }
                    .frame(height: 280)
            }
            .padding(12)
            // Pin the strips to the top so the leftover space in a tall window
            // collects below them rather than floating them in the middle.
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
