import OpenConnctUpdate
import SwiftUI

@main
struct OpenConnctApp: App {
    @StateObject private var store = ParameterStore()
    @StateObject private var updates = UpdateManager()
    @StateObject private var localAPI = LocalAPIController()
    private let engine = AudioEngine()

    var body: some Scene {
        WindowGroup("OpenConnct") {
            RootView()
                .environmentObject(store)
                .environmentObject(updates)
                .environmentObject(localAPI)
                // maxWidth/maxHeight .infinity are the load-bearing part. With
                // only min and ideal set, the content refuses to grow past its
                // ideal size, so any window larger than the ideal left the
                // whole interface as a small band floating in the middle of a
                // black window — which is what "the window looks shifted"
                // actually was. It was never positioned wrong; it was sized
                // wrong.
                //
                // The minimum is the mixer's own, and it dropped a long way
                // when the settings moved into a sheet: with a permanent
                // detail pane the floor was the sum of two panes' minimums,
                // which meant the window could not be small even to show two
                // faders. 380x430 is one strip plus the add tile plus the
                // header bar — the smallest arrangement that is still honest,
                // and below which the strips would be clipped rather than
                // merely cramped.
                .frame(
                    minWidth: 380, idealWidth: 640, maxWidth: .infinity,
                    minHeight: 430, idealHeight: 470, maxHeight: .infinity)
                .onAppear(perform: startAudio)
        }
        // Without an explicit default the window is sized from the content's
        // ideal size on first launch and then restored at whatever size it was
        // left, which is what made it look shifted.
        .defaultSize(width: 640, height: 470)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .appInfo) {
                UpdateCommands(updates: updates)
            }
        }
    }

    private func startAudio() {
        // Attach first: the engine reports its initial device list through the
        // callback the store installs here.
        store.attach(engine: engine)
        localAPI.attach(backend: store)
        engine.requestPermissionAndStart { granted in
            store.microphonePermissionDenied = !granted
        }
        // Installing replaces the app bundle out from under this process, so
        // the audio engine has to let go of the microphones first rather than
        // being killed mid-buffer.
        updates.onWillInstall = { [engine] in engine.stop() }
        updates.startAutomaticChecks()
    }
}
