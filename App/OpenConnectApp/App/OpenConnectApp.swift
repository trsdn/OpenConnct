import SwiftUI

@main
struct OpenConnectApp: App {
    @StateObject private var store = ParameterStore()
    private let engine = AudioEngine()

    var body: some Scene {
        WindowGroup("OpenConnect") {
            RootView()
                .environmentObject(store)
                .frame(minWidth: 720, minHeight: 460)
                .onAppear(perform: startAudio)
        }
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
