import SwiftUI

// MARK: - RootView
//
// Navigation model: the mixer is always visible on the left.
// Selecting a channel strip opens that mic's detail pane on the right.

struct RootView: View {
    @EnvironmentObject var store: ParameterStore
    @State private var selectedUID: String? = nil

    // Open the first connected channel by default if nothing is selected
    private var effectiveUID: String? {
        if let sel = selectedUID, store.channels.contains(where: { $0.deviceUID == sel }) {
            return sel
        }
        return store.channels.first?.deviceUID
    }

    var body: some View {
        HSplitView {
            // Left: mixer strips
            MixerView(
                store: store,
                selectedUID: effectiveUID,
                onSelectChannel: { uid in
                    withAnimation(.easeInOut(duration: 0.18)) {
                        selectedUID = uid
                    }
                }
            )
            // Four 80pt strips already needed 368pt, so the old 360pt ceiling
            // clipped the last one; the summed meter beside them needs another
            // 72. 440 is exactly those two together — raised enough to show
            // everything, and no further, because this pane always takes its
            // maximum and every extra point here widens the whole window.
            // Four 80pt strips already needed 368pt, so the old 360pt ceiling
            // clipped the last one; the summed meter beside them needs another
            // 72. 440 is exactly those two together — raised enough to show
            // everything, and no further, because this pane always takes its
            // maximum and every extra point here is taken from the detail pane.
            .frame(minWidth: 160, idealWidth: 440, maxWidth: 440, maxHeight: .infinity)

            // Right: detail pane or placeholder
            Group {
                if let uid = effectiveUID,
                   let settings = store.channels.first(where: { $0.deviceUID == uid }) {
                    MicDetailView(
                        settings: settings,
                        connection: store.meterHub.connection(for: uid),
                        meterSource: store.meterHub.meterSource(for: uid),
                        store: store)
                } else {
                    detailPlaceholder
                }
            }
            .frame(minWidth: 360, idealWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.bg)
        .onChange(of: store.channels) { channels in
            // If the selected mic was disconnected, fall back to first available
            if let sel = selectedUID, !channels.contains(where: { $0.deviceUID == sel }) {
                selectedUID = channels.first?.deviceUID
            }
        }
    }

    @ViewBuilder
    private var detailPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 40))
                .foregroundColor(Theme.textDisabled)
            Text("Select a microphone")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
    }
}
