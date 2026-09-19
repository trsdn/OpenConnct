import SwiftUI

/// The application's settings, opened from OpenConnct ▸ Settings… (⌘,).
///
/// The one setting here is the opt-in for the local control API. It used to live
/// in the diagnostics popover, next to the other capability that is off until
/// asked for, and nobody looks for a setting in a diagnostics panel.
struct SettingsView: View {
    @ObservedObject var api: LocalAPIController

    var body: some View {
        LocalAPISection(api: api)
            .padding(20)
            .frame(width: 440, alignment: .leading)
            .background(Theme.panel)
            // The app draws its own dark interface; a light system setting would
            // otherwise put its grey text on a white window.
            .preferredColorScheme(.dark)
    }
}
