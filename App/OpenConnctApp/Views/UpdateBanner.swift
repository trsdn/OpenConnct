import OpenConnctUpdate
import SwiftUI

// MARK: - UpdateCommands
//
// The app menu's update items. A separate view so the menu follows the
// manager's state; OpenConnctApp itself only owns the UpdateManager.

struct UpdateCommands: View {
    @ObservedObject var updates: UpdateManager

    var body: some View {
        Button("Check for Updates…") {
            Task { await updates.check(userInitiated: true) }
        }
        .disabled(updates.isBusy)
        Toggle("Check for Updates Automatically", isOn: $updates.automaticChecksEnabled)
    }
}

// MARK: - UpdateBanner
//
// Shown only when there is something for the user to do, same rule as
// DriverBanner right above it in RootView: nothing here costs a pixel of the
// window's small footprint unless a check found something. Ranked below the
// driver banner on purpose — a missing driver stops the mixer from working at
// all, a pending update does not.

struct UpdateBanner: View {
    @ObservedObject var updates: UpdateManager

    var body: some View {
        switch updates.state {
        case .idle:
            EmptyView()
        case .upToDate:
            // Only ever reached from a check the user asked for (see
            // UpdateManager.check) — an automatic check that finds nothing
            // stays silent instead. Having asked, the user gets an answer.
            row(
                icon: "checkmark.circle", title: "OpenConnct is up to date", explanation: "",
                buttonTitle: "OK", isBusy: false,
                action: { Task { await updates.dismiss() } })
        case .checking:
            row(icon: "hourglass", title: "Checking for updates…", explanation: "")
        case .downloading(let version):
            row(icon: "arrow.down.circle", title: "Downloading OpenConnct \(version)…", explanation: "")
        case .readyToInstall(let version):
            row(
                icon: "arrow.down.circle.fill",
                title: "OpenConnct \(version) is ready to install",
                explanation: "Installing quits OpenConnct, replaces it and opens it again. "
                    + "Audio through the OpenConnct Mic device stops for a few seconds.",
                buttonTitle: "Install and Restart",
                isBusy: false,
                action: { Task { await updates.installAndRelaunch() } })
        case .installing:
            row(icon: "hourglass", title: "Installing the update…", explanation: "")
        case .failed(let message):
            row(
                icon: "exclamationmark.triangle.fill", title: "Update check failed",
                explanation: message, buttonTitle: "OK", isBusy: false,
                action: { Task { await updates.dismiss() } }, tint: Theme.meterAmber)
        case .installFailed(let message):
            row(
                icon: "exclamationmark.triangle.fill",
                title: "Update failed to install",
                explanation: message,
                buttonTitle: "Restart OpenConnct",
                isBusy: false,
                action: { NSApp.terminate(nil) },
                tint: Theme.meterRed)
        }
    }

    @ViewBuilder
    private func row(
        icon: String,
        title: String,
        explanation: String,
        buttonTitle: String? = nil,
        isBusy: Bool = false,
        action: (() -> Void)? = nil,
        tint: Color = Theme.textSecondary
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .foregroundColor(tint)
                    .font(.system(size: 13, weight: .semibold))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(Theme.titleFont)
                        .foregroundColor(Theme.textPrimary)
                    if !explanation.isEmpty {
                        Text(explanation)
                            .font(Theme.captionFont)
                            .foregroundColor(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 12)

                if let buttonTitle, let action {
                    Button(action: action) {
                        Text(buttonTitle)
                            .font(Theme.labelFont)
                            .foregroundColor(Theme.textPrimary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: Theme.radiusSmall)
                                    .fill(Theme.accent))
                    }
                    .buttonStyle(.plain)
                    .disabled(isBusy)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.raised)
    }
}
