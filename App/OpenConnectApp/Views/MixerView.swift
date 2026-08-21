import SwiftUI
import AppKit

// MARK: - DiagnosticsBar

private struct DiagnosticsBar: View {
    let diagnostics: EngineDiagnostics

    private var hasIssues: Bool {
        diagnostics.underruns > 0 || diagnostics.overruns > 0 || diagnostics.droppedParameters > 0
    }

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(diagnostics.running ? Theme.meterGreen : Theme.meterRed)
                .frame(width: 6, height: 6)

            Text(diagnostics.running ? "Engine running" : "Engine stopped")
                .font(Theme.captionFont)
                .foregroundColor(diagnostics.running ? Theme.textSecondary : Theme.meterRed)

            if diagnostics.underruns > 0 {
                xrunBadge("XRun", count: Int(diagnostics.underruns))
            }
            if diagnostics.overruns > 0 {
                xrunBadge("OVR", count: Int(diagnostics.overruns))
            }
            if diagnostics.droppedParameters > 0 {
                xrunBadge("DROP", count: Int(diagnostics.droppedParameters))
            }

            if !diagnostics.perChannelRatioPPM.isEmpty {
                ForEach(diagnostics.perChannelRatioPPM.sorted(by: { $0.key < $1.key }), id: \.key) { uid, ppm in
                    Text(String(format: "%.0f ppm", ppm))
                        .font(Theme.captionFont)
                        .foregroundColor(abs(ppm) > 100 ? Theme.meterAmber : Theme.textSecondary)
                }
            }

            Spacer()

            if !diagnostics.sinkAvailable {
                Text("Sink unavailable")
                    .font(Theme.captionFont)
                    .foregroundColor(Theme.meterAmber)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(Theme.panel)
    }

    @ViewBuilder
    private func xrunBadge(_ label: String, count: Int) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .font(Theme.captionFont)
                .foregroundColor(.black)
            Text("\(count)")
                .font(Theme.captionFont.bold())
                .foregroundColor(.black)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 3).fill(Theme.meterRed))
    }
}

// MARK: - Empty state

private struct EmptyMicView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "mic.slash")
                .font(.system(size: 48))
                .foregroundColor(Theme.textDisabled)
            Text("No microphones connected")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(Theme.textSecondary)
            Text("Connect a USB microphone and it will appear here.")
                .font(Theme.captionFont)
                .foregroundColor(Theme.textDisabled)
                .multilineTextAlignment(.center)
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

    var body: some View {
        VStack(spacing: 0) {
            DiagnosticsBar(diagnostics: store.diagnostics)
            Divider().background(Theme.border)

            if store.microphonePermissionDenied {
                PermissionDeniedView()
            } else if store.channels.isEmpty {
                EmptyMicView()
            } else {
                stripArea
            }
        }
        .background(Theme.bg)
    }

    @ViewBuilder
    private var stripArea: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 8) {
                ForEach(store.channels) { ch in
                    let m = store.meters[ch.deviceUID] ?? ChannelMeters()
                    ChannelStripView(
                        settings: ch,
                        meters: m,
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
