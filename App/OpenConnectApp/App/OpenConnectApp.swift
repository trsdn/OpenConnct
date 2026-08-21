import SwiftUI

@main
struct OpenConnectApp: App {
    @StateObject private var store = ParameterStore()
    private let engine = AudioEngine()

    var body: some Scene {
        WindowGroup("OpenConnect") {
            RootView()
                .environmentObject(store)
                .frame(minWidth: 760, idealWidth: 900, minHeight: 520, idealHeight: 620)
                .onAppear(perform: startAudio)
        }
        // Without an explicit default the window is sized from the content's
        // ideal size on first launch and then restored at whatever size it was
        // left, which is what made it look shifted.
        .defaultSize(width: 900, height: 620)
        .windowResizability(.contentMinSize)
    }

    private func startAudio() {
        // Attach first: the engine reports its initial device list through the
        // callback the store installs here.
        store.attach(engine: engine)
        engine.requestPermissionAndStart { granted in
            store.microphonePermissionDenied = !granted
        }
    }
}
