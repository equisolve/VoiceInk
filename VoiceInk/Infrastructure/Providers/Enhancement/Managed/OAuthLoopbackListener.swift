import Foundation
import Network
import os

/// Waits for one OAuth redirect on `http://127.0.0.1:<port>/<path>`, as RFC 8252 describes for native apps.
///
/// The listener binds to 127.0.0.1 only, on a port the system picks, so other computers can't reach it. It answers
/// the first callback request whose `state` matches with a page that says the tab can be closed, returns that
/// request's target (path and query), and stops. A callback request with any other `state` gets a 400 and the listener
/// keeps waiting, so another program on this Mac that finds the port can't end the sign-in. Requests for other paths,
/// such as the browser's favicon, get a 404.
///
/// The timeout starts when `start()` is called. When no matching callback arrives in time, starting or waiting fails
/// with `ManagedAISignInError.timedOut`. Canceling the task that's starting or waiting stops the listener and throws
/// `CancellationError`.
final class OAuthLoopbackListener: @unchecked Sendable {
    private let callbackPath: String
    private let expectedState: String
    private let timeout: TimeInterval
    private let queue = DispatchQueue(label: "com.prakashjoshipax.voiceink.oauth-loopback")
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "OAuthLoopbackListener")

    // Read and written only on `queue`.
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var result: Result<String, Error>?
    private var starter: CheckedContinuation<UInt16, Error>?
    private var waiter: CheckedContinuation<String, Error>?

    static let callbackPage = """
        <!doctype html>
        <html><head><meta charset="utf-8"><title>VoiceInk</title></head>
        <body style="font-family: -apple-system, sans-serif; margin: 4em auto; max-width: 32em; text-align: center;">
        <h1>You can close this tab</h1>
        <p>Return to VoiceInk to finish signing in.</p>
        </body></html>
        """

    static let mismatchPage = """
        <!doctype html>
        <html><head><meta charset="utf-8"><title>VoiceInk</title></head>
        <body style="font-family: -apple-system, sans-serif; margin: 4em auto; max-width: 32em; text-align: center;">
        <h1>This sign-in link is out of date</h1>
        <p>Return to VoiceInk and sign in again.</p>
        </body></html>
        """

    init(callbackPath: String, expectedState: String, timeout: TimeInterval) {
        self.callbackPath = callbackPath
        self.expectedState = expectedState
        self.timeout = timeout
    }

    /// Starts listening and returns the port.
    func start() async throws -> UInt16 {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { self.startOnQueue(continuation) }
            }
        } onCancel: {
            self.cancel()
        }
    }

    /// Returns the target of the callback request, such as `/oauth/callback?code=...&state=...`.
    func waitForCallback() async throws -> String {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    if let result = self.result {
                        continuation.resume(with: result)
                    } else {
                        self.waiter = continuation
                    }
                }
            }
        } onCancel: {
            self.cancel()
        }
    }

    func cancel() {
        queue.async { self.finishOnQueue(.failure(CancellationError())) }
    }

    private func startOnQueue(_ continuation: CheckedContinuation<UInt16, Error>) {
        if let result {
            // Canceled or already finished before the listener started.
            if case .failure(let error) = result {
                continuation.resume(throwing: error)
            } else {
                continuation.resume(throwing: ManagedAISignInError.listenerFailed)
            }
            return
        }

        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        parameters.acceptLocalOnly = true
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            logger.error("Couldn't create the sign-in listener: \(error.localizedDescription, privacy: .public)")
            finishOnQueue(.failure(ManagedAISignInError.listenerFailed))
            continuation.resume(throwing: ManagedAISignInError.listenerFailed)
            return
        }

        self.listener = listener
        starter = continuation
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            self?.listenerStateChanged(state)
        }
        // The timeout also covers a listener that stays in the waiting state and never becomes ready.
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.finishOnQueue(.failure(ManagedAISignInError.timedOut))
        }
        listener.start(queue: queue)
    }

    private func listenerStateChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            guard let starter else { return }
            guard let port = listener?.port?.rawValue, port != 0 else {
                finishOnQueue(.failure(ManagedAISignInError.listenerFailed))
                return
            }
            self.starter = nil
            starter.resume(returning: port)
        case .failed(let error):
            logger.error("The sign-in listener failed: \(error.localizedDescription, privacy: .public)")
            finishOnQueue(.failure(ManagedAISignInError.listenerFailed))
        case .cancelled:
            finishOnQueue(.failure(CancellationError()))
        default:
            break
        }
    }

    private func finishOnQueue(_ result: Result<String, Error>) {
        guard self.result == nil else { return }
        self.result = result
        listener?.cancel()
        listener = nil
        for connection in connections.values {
            connection.cancel()
        }
        connections.removeAll()

        if let starter {
            self.starter = nil
            if case .failure(let error) = result {
                starter.resume(throwing: error)
            } else {
                starter.resume(throwing: ManagedAISignInError.listenerFailed)
            }
        }
        waiter?.resume(with: result)
        waiter = nil
    }

    private func handle(_ connection: NWConnection) {
        guard result == nil else { return connection.cancel() }
        connections[ObjectIdentifier(connection)] = connection
        connection.start(queue: queue)
        receiveRequest(on: connection, buffer: Data())
    }

    private func close(_ connection: NWConnection) {
        connections.removeValue(forKey: ObjectIdentifier(connection))
        connection.cancel()
    }

    private func receiveRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, isComplete, error in
            guard let self else { return connection.cancel() }
            var buffer = buffer
            if let data { buffer.append(data) }

            if buffer.range(of: Data("\r\n\r\n".utf8)) != nil {
                if let target = Self.requestTarget(in: buffer) {
                    self.respond(to: target, on: connection)
                } else {
                    self.close(connection)
                }
            } else if error != nil || isComplete || buffer.count > 16_384 {
                self.close(connection)
            } else {
                self.receiveRequest(on: connection, buffer: buffer)
            }
        }
    }

    private func respond(to target: String, on connection: NWConnection) {
        let components = URLComponents(string: target)
        let status: String
        let body: String
        var matched = false

        if components?.path != callbackPath || result != nil {
            (status, body) = ("404 Not Found", "Not found")
        } else if components?.queryItems?.first(where: { $0.name == "state" })?.value == expectedState {
            (status, body) = ("200 OK", Self.callbackPage)
            matched = true
        } else {
            logger.error("Ignored a sign-in callback whose state didn't match")
            (status, body) = ("400 Bad Request", Self.mismatchPage)
        }

        if matched {
            // Finishing closes every open connection, so let this one close after its page is sent.
            connections.removeValue(forKey: ObjectIdentifier(connection))
        }
        connection.send(
            content: Self.httpResponse(status: status, body: body),
            completion: .contentProcessed { [weak self] _ in
                if let self {
                    self.close(connection)
                } else {
                    connection.cancel()
                }
            })
        if matched {
            finishOnQueue(.success(target))
        }
    }

    /// The request target from a request's first line, once the headers are complete. Nil until then, and for a
    /// request that isn't a GET for a path.
    static func requestTarget(in data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8), text.contains("\r\n\r\n"),
            let requestLine = text.components(separatedBy: "\r\n").first
        else {
            return nil
        }
        let parts = requestLine.split(separator: " ")
        guard parts.count == 3, parts[0] == "GET", parts[1].hasPrefix("/") else { return nil }
        return String(parts[1])
    }

    private static func httpResponse(status: String, body: String) -> Data {
        let bodyData = Data(body.utf8)
        let headers = [
            "HTTP/1.1 \(status)",
            "Content-Type: text/html; charset=utf-8",
            "Content-Length: \(bodyData.count)",
            "Cache-Control: no-store",
            "Connection: close",
            "", "",
        ].joined(separator: "\r\n")
        return Data(headers.utf8) + bodyData
    }
}
