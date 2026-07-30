import Foundation

/// Shared Anthropic Messages API client used by cache analysis, malware review,
/// Homebrew insights, and login-item AI. One request shape, one header set, one
/// model table — call sites only supply the prompt and the model tier they need.
enum AnthropicMessagesClient {
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    static let apiVersion = "2023-06-01"
    static let defaultTimeout: TimeInterval = 30

    enum Model: String, Sendable {
        case haiku = "claude-haiku-4-5"
        case sonnet = "claude-sonnet-4-5"
        case opus = "claude-opus-4-5"
    }

    enum ClientError: Error, LocalizedError, Sendable {
        case invalidRequestBody
        case emptyResponse
        case unparseableResponse
        case httpFailure(status: Int, body: String)
        case transport(String)

        var errorDescription: String? {
            switch self {
            case .invalidRequestBody:
                return "Could not encode Anthropic request body"
            case .emptyResponse:
                return "Anthropic API returned an empty response"
            case .unparseableResponse:
                return "Anthropic API returned an unparseable response"
            case .httpFailure(let status, let body):
                let snippet = body.trimmingCharacters(in: .whitespacesAndNewlines)
                if snippet.isEmpty {
                    return "Anthropic API failed with HTTP \(status)"
                }
                return "Anthropic API failed with HTTP \(status): \(snippet.prefix(200))"
            case .transport(let message):
                return message
            }
        }
    }

    /// POST a user prompt (optional system prompt) and return the first text block.
    static func complete(
        prompt: String,
        apiKey: String,
        model: Model,
        maxTokens: Int = 2048,
        system: String? = nil,
        timeout: TimeInterval = defaultTimeout,
        session: URLSession = .shared
    ) async throws -> String {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")

        var body: [String: Any] = [
            "model": model.rawValue,
            "max_tokens": maxTokens,
            "messages": [["role": "user", "content": prompt]]
        ]
        if let system, !system.isEmpty {
            body["system"] = system
        }

        guard let httpBody = try? JSONSerialization.data(withJSONObject: body) else {
            throw ClientError.invalidRequestBody
        }
        request.httpBody = httpBody

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ClientError.transport(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw ClientError.httpFailure(status: http.statusCode, body: bodyText)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let text = content.first?["text"] as? String
        else {
            throw ClientError.unparseableResponse
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ClientError.emptyResponse }
        return trimmed
    }

    /// Prefer an embedded JSON array when the model wraps it in prose or fences.
    static func extractJSONArray(from text: String) -> String {
        let cleaned = stripMarkdownFence(text)
        if let start = cleaned.firstIndex(of: "["), let end = cleaned.lastIndex(of: "]"), start <= end {
            return String(cleaned[start...end])
        }
        return cleaned
    }

    static func stripMarkdownFence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```") else { return trimmed }
        var lines = trimmed.components(separatedBy: .newlines)
        if !lines.isEmpty { lines.removeFirst() }
        if lines.last?.trimmingCharacters(in: .whitespacesAndNewlines) == "```" {
            lines.removeLast()
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
