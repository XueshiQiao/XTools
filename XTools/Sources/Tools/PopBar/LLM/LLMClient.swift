import Foundation

/// OpenAI-compatible chat client, ported from Flowy's `LLMManager`. The valuable
/// part carried over is the **per-provider thinking control** in `buildRequest`:
/// there is no single field that disables reasoning everywhere, so each provider
/// gets its own knob (DeepSeek/Doubao: `thinking={type:disabled}` to turn off,
/// `reasoning_effort` for graded depth; Qwen: `enable_thinking=false`;
/// Ollama: `/no_think` prefix; OpenAI: graded `reasoning_effort`, no off-switch).
struct LLMClient {

    let config: LLMConfig
    private let endpointURL: URL
    private let timeout: TimeInterval

    init(config: LLMConfig, timeout: TimeInterval = 30) {
        self.config = config
        self.timeout = timeout
        if config.provider == "ollama",
           var comps = URLComponents(string: config.apiURL),
           comps.path.hasSuffix("/api/chat") {
            comps.path = "/v1/chat/completions"
            self.endpointURL = comps.url!
        } else {
            var url = config.apiURL
            if !url.hasSuffix("/chat/completions") {
                url = url.hasSuffix("/") ? url + "chat/completions" : url + "/chat/completions"
            }
            self.endpointURL = URL(string: url) ?? URL(string: "https://api.deepseek.com/chat/completions")!
        }
    }

    /// One-shot completion: system + user → assistant text. The model's reasoning
    /// trace (`reasoning_content`) is intentionally not read — we only want the
    /// answer — and any inline `<think>…</think>` is stripped defensively.
    func complete(system: String, user: String) async throws -> String {
        var systemPrompt = system
        if config.provider == "ollama" && config.reasoningEffort == "none" {
            systemPrompt = "/no_think\n\(systemPrompt)"
        }
        let messages: [[String: String]] = [
            ["role": "system", "content": systemPrompt],
            ["role": "user", "content": user],
        ]
        let request = try buildRequest(messages: messages)
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response, data: data)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String
        else {
            throw LLMError.badResponse("Unexpected response shape")
        }
        return Self.stripThinkTags(content).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Request building (Flowy's per-provider thinking logic)

    private func buildRequest(messages: [[String: String]]) throws -> URLRequest {
        var body: [String: Any] = [
            "model": config.model,
            "messages": messages,
            "stream": false,
        ]

        let effort = LLMConfig.clampThinking(config.reasoningEffort, for: config.provider)
        if config.provider == "alibaba" {
            // DashScope: non-streaming must disable thinking; also honor explicit off.
            body["enable_thinking"] = false
        } else {
            // doubao / deepseek: thinking on/off switch + graded reasoning_effort.
            // openai / ollama: graded reasoning_effort, no off-switch object.
            let usesThinkingSwitch = config.provider == "doubao" || config.provider == "deepseek"
            switch effort {
            case "":
                break
            case "none":
                if usesThinkingSwitch { body["thinking"] = ["type": "disabled"] }
            default:
                body["reasoning_effort"] = effort
            }
        }

        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !config.apiKey.isEmpty {
            request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private func validate(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200...299).contains(http.statusCode) else {
            // Surface the API's message (e.g. 401 invalid key) but not our request.
            let body = String(data: data, encoding: .utf8) ?? ""
            let snippet = body.count > 300 ? String(body.prefix(300)) + "…" : body
            throw LLMError.http(status: http.statusCode, message: snippet)
        }
    }

    /// Remove any inline chain-of-thought some models emit despite the off-switch.
    private static func stripThinkTags(_ text: String) -> String {
        guard text.contains("<think>") else { return text }
        guard let regex = try? NSRegularExpression(
            pattern: "<think>[\\s\\S]*?</think>", options: []) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }
}

enum LLMError: LocalizedError {
    case http(status: Int, message: String)
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .http(let status, let message): return "HTTP \(status): \(message)"
        case .badResponse(let message):      return message
        }
    }
}
