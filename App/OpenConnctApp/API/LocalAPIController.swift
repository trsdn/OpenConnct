import Foundation

/// Owns the one switch that turns the local API on, and the server it controls.
///
/// **Off by default and stays off until the user says otherwise.** An app that
/// opens a listening socket unasked, even one bound to loopback, has earned the
/// suspicion it gets; the choice is persisted so it survives a relaunch, and
/// nothing listens until it is made.
@MainActor
final class LocalAPIController: ObservableObject {
    private static let enabledKey = "localAPIEnabled"

    @Published private(set) var isEnabled: Bool
    /// The port currently bound, or nil while off or when binding failed.
    @Published private(set) var port: UInt16?

    private var server: LocalAPIServer?
    private weak var backend: LocalAPIBackend?

    init() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
    }

    /// Called once the mixer exists. Starts listening if the user had it on.
    func attach(backend: LocalAPIBackend) {
        self.backend = backend
        if isEnabled { startServer() }
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        if enabled { startServer() } else { stopServer() }
    }

    private func startServer() {
        guard server == nil, let backend else { return }
        let server = LocalAPIServer(backend: backend)
        server.onPortChanged = { [weak self] port in self?.port = port }
        self.server = server
        server.start()
    }

    private func stopServer() {
        server?.stop()
        server = nil
        port = nil
    }
}
