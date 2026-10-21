import Foundation
import LLMkit
import os

/// Sends chat completion requests to the organization's AI endpoint (see `ManagedAIEndpoint`).
///
/// The body carries only `model`, `messages`, and `stream`. Sampling settings such as `temperature` belong to the
/// proxy, because some models behind it refuse them: Claude Haiku 5.5 on Bedrock rejects any `temperature`, and a
/// LiteLLM proxy without `drop_params` passes that rejection back as a 400.
///
/// Redirects are followed only to the endpoint's own scheme, host, and port, so the token is never sent to another
/// server, even when the endpoint redirects to one.
enum ManagedAIClient {
    private static let retryableStatusCodes: Set<Int> = [429, 500, 502, 503, 504]

    static func requestBody(model: String, messages: [ChatMessage], systemPrompt: String?) -> [String: Any] {
        var allMessages = messages
        if let systemPrompt, !systemPrompt.isEmpty {
            allMessages.insert(.system(systemPrompt), at: 0)
        }
        return [
            "model": model,
            "messages": allMessages.map { ["role": $0.role, "content": $0.content] },
            "stream": false,
        ]
    }

    /// Makes the configuration for each request's session. Tests replace it to add a stub protocol.
    static var makeSessionConfiguration: () -> URLSessionConfiguration = { .ephemeral }

    static func chatCompletion(
        endpoint: ManagedAIEndpoint,
        token: String,
        messages: [ChatMessage],
        systemPrompt: String?,
        timeout: TimeInterval,
        maxRetries: Int = 2
    ) async throws -> String {
        var request = URLRequest(url: endpoint.chatCompletionsURL)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        guard
            let body = try? JSONSerialization.data(
                withJSONObject: requestBody(model: endpoint.model, messages: messages, systemPrompt: systemPrompt))
        else {
            throw LLMKitError.encodingError
        }
        request.httpBody = body

        let configuration = makeSessionConfiguration()
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil

        var attempt = 0
        while true {
            let (data, response) = try await send(request, endpoint: endpoint, configuration: configuration)
            guard let http = response as? HTTPURLResponse else {
                throw LLMKitError.networkError("No HTTP response from the organization AI endpoint.")
            }

            if (300...399).contains(http.statusCode) {
                // The redirect guard refused to follow it, so the redirect response is the final response.
                let target = http.value(forHTTPHeaderField: "Location") ?? "another URL"
                throw ManagedAIClientError.redirectRefused(target: target)
            }

            if retryableStatusCodes.contains(http.statusCode), attempt < maxRetries {
                attempt += 1
                try await Task.sleep(nanoseconds: UInt64(pow(2.0, Double(attempt - 1)) * 1_000_000_000))
                continue
            }

            guard (200...299).contains(http.statusCode) else {
                let message = String(data: data, encoding: .utf8) ?? ""
                throw LLMKitError.httpError(statusCode: http.statusCode, message: message)
            }

            return try decodeContent(data)
        }
    }

    private static func send(
        _ request: URLRequest,
        endpoint: ManagedAIEndpoint,
        configuration: URLSessionConfiguration
    ) async throws -> (Data, URLResponse) {
        let session = URLSession(
            configuration: configuration,
            delegate: ManagedEndpointRedirectGuard(endpoint: endpoint),
            delegateQueue: nil
        )
        defer { session.finishTasksAndInvalidate() }

        do {
            return try await session.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw LLMKitError.timeout
        } catch let error as URLError {
            throw LLMKitError.networkError(error.localizedDescription)
        }
    }

    private static func decodeContent(_ data: Data) throws -> String {
        struct Response: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String? }
                let message: Message
            }
            let choices: [Choice]
        }

        do {
            return try JSONDecoder().decode(Response.self, from: data).choices.first?.message.content ?? ""
        } catch {
            throw LLMKitError.decodingError(error.localizedDescription)
        }
    }
}

enum ManagedAIClientError: LocalizedError, Equatable {
    case redirectRefused(target: String)

    var errorDescription: String? {
        switch self {
        case .redirectRefused(let target):
            return String(
                localized: "The organization AI endpoint redirected to \(target). VoiceInk follows redirects only within the endpoint's own address."
            )
        }
    }
}

/// Follows a redirect only when it stays on the managed endpoint's scheme, host, and port.
final class ManagedEndpointRedirectGuard: NSObject, URLSessionTaskDelegate {
    private let endpoint: ManagedAIEndpoint
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "ManagedAIClient")

    init(endpoint: ManagedAIEndpoint) {
        self.endpoint = endpoint
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        guard let url = request.url, CloudPolicy.hasManagedEndpointOrigin(url, managedEndpoint: endpoint) else {
            logger.error(
                "Refused a redirect from the organization AI endpoint to \(request.url?.host ?? "an unknown host", privacy: .public)"
            )
            return nil
        }
        return request
    }
}
