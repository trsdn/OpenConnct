import SwiftUI

/// A row label with its processing badge, at a fixed width so the controls to
/// the right of it line up between rows.
struct RowLabel: View {
    let text: String
    let location: ProcessingLocation

    var body: some View {
        HStack(spacing: 5) {
            Text(text)
                .font(Theme.labelFont)
                .foregroundColor(Theme.textSecondary)
            ProcessingBadge(location: location)
        }
        .frame(width: 74, alignment: .leading)
    }
}

/// A small chip saying whether a control takes effect inside the microphone or
/// in this app.
///
/// Only worth showing where the answer could go either way — that is, on the
/// preamp-family controls. Putting one of these on the compressor would be
/// noise: nobody wonders whether a USB microphone has a compressor in it.
///
/// The device state is deliberately the *quieter* of the two, tinted rather than
/// filled. The accent colour means "this is on and affecting your sound"
/// everywhere else in the interface, and a badge is a statement of fact, not a
/// control.
///
/// Blue rather than green for the same reason: green already means "this effect
/// is switched on" on the buttons directly below, and amber and red are taken by
/// solo and by the accent. A colour that is not already carrying a meaning reads
/// as information instead of as a state.
struct ProcessingBadge: View {
    let location: ProcessingLocation

    /// Not in `Theme` because it is used nowhere else, and putting a one-off in
    /// the palette invites it to be reused as if it meant something general.
    private static let deviceTint = Color(red: 0.42, green: 0.66, blue: 0.92)

    var body: some View {
        Text(location.badgeText)
            .font(.system(size: 9, weight: .bold, design: .default))
            .tracking(0.4)
            .foregroundColor(foreground)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: Theme.radiusSmall)
                    .fill(background)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.radiusSmall)
                            .stroke(border, lineWidth: 1)))
            .help(explanation)
            .accessibilityLabel(Text(accessibilityText))
    }

    private var foreground: Color {
        location.isDevice ? Self.deviceTint : Theme.textSecondary
    }

    private var background: Color {
        location.isDevice ? Self.deviceTint.opacity(0.14) : Theme.raised
    }

    private var border: Color {
        location.isDevice ? Self.deviceTint.opacity(0.40) : Theme.border
    }

    private var explanation: String {
        location.isDevice
            ? "The microphone does this itself, before its own converter. "
                + "That is slightly quieter than doing it here."
            : "OpenConnct does this, after the signal has been digitised. "
                + "Your microphone may have a switch of its own for it too, which "
                + "the computer cannot see."
    }

    private var accessibilityText: String {
        location.isDevice ? "Handled by the microphone" : "Handled by OpenConnct"
    }
}
