import SwiftUI

/// The opt-in for the local control API, in the diagnostics popover next to the
/// other capability that is off until asked for.
///
/// Says what turning it on exposes, in the same plain terms as the Input
/// Monitoring note above it: the reader should be able to decide without
/// knowing what a loopback interface is.
struct LocalAPISection: View {
    @ObservedObject var api: LocalAPIController

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(get: { api.isEnabled }, set: { api.setEnabled($0) })) {
                Text("Control from other apps")
                    .font(Theme.labelFont)
                    .foregroundColor(Theme.textSecondary)
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            Text(explanation)
                .font(Theme.captionFont)
                .foregroundColor(Theme.textDisabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var explanation: String {
        if !api.isEnabled {
            return "Off. When on, a script or a Stream Deck can mute channels, set "
                + "gain and read the mixer over a local web address. It only "
                + "listens on this Mac, never on the network, and every request "
                + "needs a secret key that only your user account can read."
        }
        guard let port = api.port else {
            return "On, but it could not start listening. Turn it off and on again."
        }
        return "On at http://127.0.0.1:\(port). The port and the secret key are in "
            + "~/Library/Application Support/OpenConnct/ (api-port, api-token). "
            + "Send the key as “Authorization: Bearer …”."
    }
}
