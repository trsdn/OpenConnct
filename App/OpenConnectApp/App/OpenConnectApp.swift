import SwiftUI

@main
struct OpenConnectApp: App {
    @StateObject private var store = ParameterStore()
    private let engine = AudioEngine()

    var body: some Scene {
        WindowGroup("OpenConnect") {
            RootView()
                .environmentObject(store)
                // maxWidth/maxHeight .infinity are the load-bearing part. With
                // only min and ideal set, the content refuses to grow past its
                // ideal size, so any window larger than 900x620 left the whole
                // interface as a small band floating in the middle of a black
                // window — which is what "the window looks shifted" actually
                // was. It was never positioned wrong; it was sized wrong.
                .frame(
                    minWidth: 760, idealWidth: 900, maxWidth: .infinity,
                    minHeight: 520, idealHeight: 620, maxHeight: .infinity)
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
