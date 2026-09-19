import Foundation
import Network

/// Serves the local control API on the loopback interface, and nowhere else.
///
/// Bound to `127.0.0.1` explicitly through `requiredLocalEndpoint`: never to
/// all interfaces, so the API is unreachable from the network whatever the
/// firewall says. All the decisions — token, `Origin`, routing, what a request
/// may do — live in `LocalAPIDispatcher`, which is tested; this type only moves
/// bytes and is deliberately too thin to hold a bug worth having.
///
/// One request per connection, answered and closed. A connection that has not
/// produced a complete request within `requestTimeout` is dropped, so an idle
/// or trickling client cannot hold a socket.
@MainActor
final class LocalAPIServer {
    /// Tried first so a script can work with no discovery at all; the file is
    /// the fallback when something else already owns it.
    static let defaultPort: UInt16 = 47831
    private static let requestTimeout: TimeInterval = 5

    private let backend: LocalAPIBackend
    private let token = LocalAPICredentials.loadOrCreateToken()
    private let queue = DispatchQueue(label: "audio.openconnct.localapi")
    private var listener: NWListener?

    /// Called on the main actor with the bound port once listening, or nil when
    /// the listener could not start at all.
    var onPortChanged: ((UInt16?) -> Void)?

    init(backend: LocalAPIBackend) {
        self.backend = backend
    }

    func start() {
        guard listener == nil else { return }
        listen(on: Self.defaultPort, allowFallback: true)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        LocalAPICredentials.retractPort()
        onPortChanged?(nil)
    }

    private func listen(on port: UInt16, allowFallback: Bool) {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(
            host: .ipv4(.loopback),
            port: port == 0 ? .any : NWEndpoint.Port(rawValue: port)!)

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            NSLog("OpenConnct: local API could not create a listener: %@", "\(error)")
            onPortChanged?(nil)
            return
        }
        self.listener = listener

        listener.stateUpdateHandler = { [weak self, weak listener] state in
            Task { @MainActor in
                guard let self, let listener, self.listener === listener else { return }
                switch state {
                case .ready:
                    if let bound = listener.port?.rawValue {
                        LocalAPICredentials.publish(port: bound)
                        self.onPortChanged?(bound)
                        NSLog("OpenConnct: local API listening on 127.0.0.1:%d", Int(bound))
                    }
                case .failed(let error):
                    listener.cancel()
                    self.listener = nil
                    if allowFallback {
                        NSLog("OpenConnct: local API port %d unavailable (%@); using a free one",
                              Int(port), "\(error)")
                        self.listen(on: 0, allowFallback: false)
                    } else {
                        NSLog("OpenConnct: local API failed to start: %@", "\(error)")
                        self.onPortChanged?(nil)
                    }
                default:
                    break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.accept(connection) }
        }
        listener.start(queue: queue)
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + Self.requestTimeout) { connection.cancel() }
        receive(on: connection, buffered: Data())
    }

    private func receive(on connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self else { connection.cancel(); return }
                var buffer = buffered
                if let data { buffer.append(data) }

                switch LocalAPIRequest.framing(of: buffer) {
                case .invalid:
                    self.send(LocalAPIResponse.error(400, "bad request"), on: connection)
                case .complete:
                    guard let request = LocalAPIRequest.parse(buffer) else {
                        self.send(LocalAPIResponse.error(400, "bad request"), on: connection)
                        return
                    }
                    let response = LocalAPIDispatcher.handle(
                        request, token: self.token, backend: self.backend)
                    self.send(response, on: connection)
                case .needMore:
                    if error != nil || isComplete {
                        connection.cancel()
                    } else {
                        self.receive(on: connection, buffered: buffer)
                    }
                }
            }
        }
    }

    private func send(_ response: LocalAPIResponse, on connection: NWConnection) {
        connection.send(content: response.serialized(), contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { _ in connection.cancel() })
    }
}
