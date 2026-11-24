import Foundation
import Network

/// What the identity provider sent to the redirect URI.
public struct OIDCCallback: Sendable, Equatable {
    public var state: String?
    public var code: String?
    /// The provider's `error_description`, or its `error`, when the login was refused.
    public var error: String?
}

/// A listener on the loopback interface that receives the browser's redirect of an OIDC login.
public final class OIDCCallbackListener: @unchecked Sendable {
    static let path = "/oidc/callback"

    private let listener: NWListener
    private let queue = DispatchQueue(label: "OIDCCallbackListener")
    private let callbacks: AsyncThrowingStream<OIDCCallback, Error>
    private let continuation: AsyncThrowingStream<OIDCCallback, Error>.Continuation

    public init(port: Int) throws {
        guard let port = UInt16(exactly: port), let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw VaultError.oidc("\(port) is not a port number.")
        }
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        listener = try NWListener(using: parameters, on: endpointPort)
        (callbacks, continuation) = AsyncThrowingStream.makeStream()
    }

    /// Resumes a continuation once; the listener's handlers run on one serial queue.
    private final class Resumer: @unchecked Sendable {
        private var continuation: CheckedContinuation<Void, Error>?

        init(_ continuation: CheckedContinuation<Void, Error>) {
            self.continuation = continuation
        }

        func resume(_ result: Result<Void, Error>) {
            continuation?.resume(with: result)
            continuation = nil
        }
    }

    /// Starts listening and returns when connections are accepted.
    public func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let resumer = Resumer(continuation)
            listener.stateUpdateHandler = { [continuation = self.continuation] state in
                switch state {
                case .ready:
                    resumer.resume(.success(()))
                case let .failed(error):
                    resumer.resume(.failure(error))
                    continuation.finish(throwing: error)
                case .cancelled:
                    resumer.resume(.failure(CancellationError()))
                    continuation.finish()
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            listener.start(queue: queue)
        }
    }

    /// Waits for the redirect; stops waiting when the timeout passes or the task is cancelled.
    public func callback(timeout: Duration = .seconds(300)) async throws -> OIDCCallback {
        let callbacks = callbacks
        return try await withThrowingTaskGroup(of: OIDCCallback.self) { group in
            group.addTask {
                for try await callback in callbacks {
                    return callback
                }
                throw CancellationError()
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw VaultError.oidc("The browser did not return in time.")
            }
            defer {
                group.cancelAll()
            }
            guard let callback = try await group.next() else {
                throw CancellationError()
            }
            return callback
        }
    }

    public func cancel() {
        listener.cancel()
        continuation.finish()
    }

    /// The callback in the request line of an HTTP request, or nil for any other request.
    public static func parse(request: String) -> OIDCCallback? {
        let parts = (request.split(separator: "\r\n", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
            .split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET", let components = URLComponents(string: String(parts[1])),
              components.path == path else {
            return nil
        }
        var values: [String: String] = [:]
        for item in components.queryItems ?? [] {
            values[item.name] = item.value ?? ""
        }
        return OIDCCallback(state: values["state"], code: values["code"],
                            error: values["error_description"] ?? values["error"])
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, _ in
            let callback = (data.flatMap { String(data: $0, encoding: .utf8) }).flatMap(Self.parse(request:))
            let status = callback == nil ? "404 Not Found" : "200 OK"
            let page = callback == nil ? "Not found." : "Signed in. You can close this tab and return to Mac Authenticator."
            let body = "<!DOCTYPE html><html><head><meta charset=\"utf-8\"><title>Mac Authenticator</title></head><body><p>\(page)</p></body></html>"
            let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\n"
                + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            connection.send(content: Data(response.utf8), contentContext: .finalMessage, isComplete: true,
                            completion: .contentProcessed { _ in connection.cancel() })
            if let callback, let self {
                self.continuation.yield(callback)
                self.continuation.finish()
            }
        }
    }
}
