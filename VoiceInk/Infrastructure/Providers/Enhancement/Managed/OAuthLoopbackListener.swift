import Foundation
import Network
import os

/// Waits for one OAuth redirect on `http://127.0.0.1:<port>/<path>`, as RFC 8252 describes for native apps.
///
/// The listener binds to 127.0.0.1 only, on a port the system picks, so other computers can't reach it. It answers
/// the first request for the callback path with a page that says the tab can be closed, returns that request's target
/// (path and query), and stops. Requests for other paths, such as the browser's favicon, get a 404. When no callback
/// arrives before the timeout, waiting fails with `ManagedAISignInError.timedOut`.
final class OAuthLoopbackListener: @unchecked Sendable {
    private let callbackPath: String
    private let timeout: TimeInterval
    private let queue = DispatchQueue(label: "com.prakashjoshipax.voiceink.oauth-loopback")
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "OAuthLoopbackListener")

    private var listener: NWListener?
    private var result: Result<String, Error>?
    private var waiter: CheckedContinuation<String, Error>?

    static let callbackPage = """
        <!doctype html>
        <html><head><meta charset="utf-8"><title>VoiceInk</title></head>
        <body style="font-family: -apple-system, sans-serif; margin: 4em auto; max-width: 32em; text-align: center;">
        <h1>You can close this tab</h1>
        <p>Return to VoiceInk to finish signing in.</p>
        </body></html>
        """

    init(callbackPath: String, timeout: TimeInterval) {
        self.callbackPath = callbackPath
        self.timeout = timeout
    }

    /// Starts listening and returns the port.
    func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        parameters.acceptLocalOnly = true
        let listener = try NWListener(using: parameters)
        self.listener = listener

        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }

        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    guard !resumed else { return }
                    resumed = true
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error):
                    self?.logger.error("The sign-in listener failed: \(error.localizedDescription, privacy: .public)")
                    self?.finish(.failure(ManagedAISignInError.listenerFailed))
                    guard !resumed else { return }
                    resumed = true
                    continuation.resume(throwing: ManagedAISignInError.listenerFailed)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }

        guard port != 0 else {
            cancel()
            throw ManagedAISignInError.listenerFailed
        }

        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.finishOnQueue(.failure(ManagedAISignInError.timedOut))
        }
        return port
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
            self.finish(.failure(CancellationError()))
        }
    }

    func cancel() {
        finish(.failure(CancellationError()))
    }

    private func finish(_ result: Result<String, Error>) {
        queue.async { self.finishOnQueue(result) }
    }

    private func finishOnQueue(_ result: Result<String, Error>) {
        guard self.result == nil else { return }
        self.result = result
        listener?.cancel()
        listener = nil
        waiter?.resume(with: result)
        waiter = nil
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(on: connection, buffer: Data())
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
                    connection.cancel()
                }
            } else if error != nil || isComplete || buffer.count > 16_384 {
                connection.cancel()
            } else {
                self.receiveRequest(on: connection, buffer: buffer)
            }
        }
    }

    private func respond(to target: String, on connection: NWConnection) {
        let isCallback = URLComponents(string: target)?.path == callbackPath && result == nil
        let response = Self.httpResponse(
            status: isCallback ? "200 OK" : "404 Not Found",
            body: isCallback ? Self.callbackPage : "Not found")
        connection.send(
            content: response,
            completion: .contentProcessed { _ in
                connection.cancel()
            })
        if isCallback {
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
