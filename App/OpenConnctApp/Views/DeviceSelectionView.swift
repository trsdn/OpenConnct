import SwiftUI

/// Lets the user choose which of the machine's physical inputs OpenConnct
/// should mix.
///
/// The transport-type filter in `AudioDeviceManager` can only tell physical
/// inputs from software ones; it cannot know that the webcam's built-in
/// microphone is not something you want in your podcast mix. That judgement is
/// the user's, and this is where they make it.
struct DeviceSelectionView: View {
    @ObservedObject var store: ParameterStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider().background(Theme.border)

            if store.availableDevices.isEmpty {
                Text("No microphones found.")
                    .font(Theme.labelFont)
                    .foregroundColor(Theme.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(store.availableDevices) { device in
                            row(for: device)
                            Divider().background(Theme.border)
                        }
                    }
                }
            }

            Divider().background(Theme.border)
            footer
        }
        .frame(width: 420, height: 340)
        .background(Theme.bg)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Microphones")
                .font(Theme.titleFont)
                .foregroundColor(Theme.textPrimary)
            Text(store.deviceSelectionIsImplicit
                 ? "Every attached microphone is in use. The built-in one is left out — tick it if you want it."
                 : "Only ticked devices are mixed into OpenConnct Mic.")
                .font(Theme.captionFont)
                .foregroundColor(Theme.textDisabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
    }

    private func row(for device: AudioInputDevice) -> some View {
        let enabled = store.enabledDeviceUIDs.contains(device.uid)
        return Button {
            store.setDevice(device.uid, enabled: !enabled)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: enabled ? "checkmark.square.fill" : "square")
                    .foregroundColor(enabled ? Theme.accent : Theme.textDisabled)
                    .font(.system(size: 13))
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name)
                        .font(Theme.labelFont)
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(1)
                    Text(subtitle(for: device))
                        .font(Theme.captionFont)
                        .foregroundColor(Theme.textDisabled)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(height: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(device.name))
        .accessibilityValue(Text(enabled ? "In use" : "Not in use"))
        .accessibilityAddTraits(enabled ? .isSelected : [])
    }

    private func subtitle(for device: AudioInputDevice) -> String {
        let channels = device.inputChannels == 1 ? "mono" : "\(device.inputChannels) channels"
        return String(format: "%@ · %.0f kHz", channels, device.nominalSampleRate / 1000)
    }

    private var footer: some View {
        // Counted against the devices actually on the list, not against the
        // stored set. A selection made when some other interface was plugged in
        // keeps that interface's UID, and counting those read "5 of 5 in use"
        // beside a row that plainly said "not in use".
        let inUse = store.availableDevices.filter { store.enabledDeviceUIDs.contains($0.uid) }.count
        return HStack {
            Text("\(inUse) of \(store.availableDevices.count) in use")
                .font(Theme.captionFont)
                .foregroundColor(Theme.textSecondary)
                .monospacedDigit()
            Spacer()
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
        }
        .padding(14)
    }
}
