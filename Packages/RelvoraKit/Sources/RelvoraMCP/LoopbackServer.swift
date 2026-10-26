import Foundation
import Network
import os

/// A small HTTP/1.1 server bound to 127.0.0.1: one request per connection, then the connection closes. Nothing
/// outside this Mac can reach it.
public final class LoopbackServer: @unchecked Sendable {
    public enum State: Sendable, Equatable {
        case starting
        case ready(port: UInt16)
        case failed(String)
        case stopped
    }

    public typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse

    private let requestedPort: UInt16
    private let handler: Handler
    private let queue = DispatchQueue(label: "com.erickpea29.Relvora.mcp")
    private var listener: NWListener?
    /// A request that hasn't arrived completely by then is dropped.
    static let requestTimeout: TimeInterval = 15

    /// `port` 0 picks a free port (tests).
    public init(port: UInt16, handler: @escaping Handler) {
        requestedPort = port
        self.handler = handler
    }

    public func start(onStateChange: @escaping @Sendable (State) -> Void) {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(
            host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: requestedPort) ?? .any)
        parameters.allowLocalEndpointReuse = true
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            onStateChange(.failed(Self.describe(error)))
            return
        }
        self.listener = listener
        listener.stateUpdateHandler = { [weak listener] state in
            switch state {
            case .ready: onStateChange(.ready(port: listener?.port?.rawValue ?? 0))
            case .failed(let error):
                onStateChange(.failed(Self.describe(error)))
                listener?.cancel()
            case .cancelled: onStateChange(.stopped)
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        onStateChange(.starting)
        listener.start(queue: queue)
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    private static func describe(_ error: any Error) -> String {
        if case NWError.posix(let code) = error, code == .EADDRINUSE {
            return "Another app is using the port."
        }
        return error.localizedDescription
    }

    // MARK: Connections

    private func accept(_ connection: NWConnection) {
        let deadline = Deadline { connection.cancel() }
        queue.asyncAfter(deadline: .now() + Self.requestTimeout) { deadline.fire() }
        connection.start(queue: queue)
        receive(on: connection, buffer: Data(), deadline: deadline)
    }

    private func receive(on connection: NWConnection, buffer: Data, deadline: Deadline) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 << 10) {
            [weak self] content, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let content { buffer.append(content) }
            switch HTTPRequest.parse(buffer) {
            case .incomplete:
                if error != nil || isComplete {
                    connection.cancel()
                } else {
                    self.receive(on: connection, buffer: buffer, deadline: deadline)
                }
            case .invalid(let status):
                deadline.cancel()
                self.send(.text(status, HTTPResponse.reason(status)), on: connection)
            case .complete(let request):
                deadline.cancel()
                let handler = self.handler
                Task {
                    let response = await handler(request)
                    self.send(response, on: connection)
                }
            }
        }
    }

    /// Closes a connection whose request doesn't arrive in time. Used only on the server's queue.
    private final class Deadline: @unchecked Sendable {
        private var action: (() -> Void)?

        init(_ action: @escaping () -> Void) {
            self.action = action
        }

        func fire() {
            action?()
            action = nil
        }

        func cancel() {
            action = nil
        }
    }

    private func send(_ response: HTTPResponse, on connection: NWConnection) {
        connection.send(
            content: response.serialized(),
            completion: .contentProcessed { _ in connection.cancel() })
    }
}
