import SwiftUI

// MARK: - DriverBanner
//
// Shown only when there is something for the user to do: the driver is missing,
// or the app has been updated and carries a newer one than the one installed.
// The rest of the time it is not in the tree at all, so it costs nothing and
// takes no space.
//
// It sits at the very top, above the header, because when the driver is missing
// nothing else in the window works — there is no virtual device, so no meters
// and no output. Putting it below the header would rank it beneath a status
// line that is only reporting the consequence of this same problem.

struct DriverBanner: View {
    @ObservedObject var installer: DriverInstaller

    var body: some View {
        if installer.needsAction || installer.lastError != nil {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: icon)
                        .foregroundColor(Theme.meterAmber)
                        .font(.system(size: 13, weight: .semibold))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(Theme.titleFont)
                            .foregroundColor(Theme.textPrimary)
                        Text(explanation)
                            .font(Theme.captionFont)
                            .foregroundColor(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 12)

                    Button(action: { Task { await installer.install() } }) {
                        Text(installer.isInstalling ? "Installing…" : buttonTitle)
                            .font(Theme.labelFont)
                            .foregroundColor(Theme.textPrimary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: Theme.radiusSmall)
                                    .fill(Theme.accent))
                    }
                    .buttonStyle(.plain)
                    .disabled(installer.isInstalling)
                }

                if let error = installer.lastError {
                    Text(error)
                        .font(Theme.captionFont)
                        .foregroundColor(Theme.meterRed)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.raised)
        }
    }

    private var icon: String {
        installer.lastError != nil ? "exclamationmark.triangle.fill" : "arrow.down.circle.fill"
    }

    private var title: String {
        switch installer.state {
        case .notInstalled:  return "Finish setting up"
        case .outdated:      return "Update the audio driver"
        default:             return "Audio driver"
        }
    }

    // Say what will happen, including the part people dislike being surprised
    // by: an administrator prompt, and every app on the machine losing audio
    // for about a second.
    private var explanation: String {
        switch installer.state {
        case .notInstalled:
            return "OpenConnct needs to install its audio driver before it can appear "
                 + "as a microphone in Teams, Zoom or OBS. This asks for your password "
                 + "once, and briefly interrupts audio on the whole machine."
        case .outdated(let installed, let bundled):
            return "The installed driver is version \(installed); this app carries \(bundled). "
                 + "Updating asks for your password once, and briefly interrupts audio "
                 + "on the whole machine."
        default:
            return ""
        }
    }

    private var buttonTitle: String {
        if case .outdated = installer.state { return "Update" }
        return "Install"
    }
}
