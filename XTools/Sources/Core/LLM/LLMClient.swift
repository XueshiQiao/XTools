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
        let request = try buildRequest(messages: messages(system: systemPrompt(system), user: user), stream: false)
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

    /// Streaming completion: same inputs/output as `complete()`, but the assistant
    /// text is delivered incrementally via `onDelta` as Server-Sent Events arrive.
    /// `onDelta` receives the *displayed* text so far (RAW accumulation with
    /// `<think>…</think>` stripped — think tags can straddle deltas, so we re-strip
    /// the whole buffer each flush). UI updates are throttled (~50ms) here so the
    /// caller never has to; a final flush guarantees the last tokens are delivered.
    /// Returns the final stripped + trimmed text, identical in shape to `complete()`.
    /// Honors Swift `Task` cancellation — `URLSession.bytes` aborts the connection.
    func stream(system: String, user: String, onDelta: @escaping (String) -> Void) async throws -> String {
        let request = try buildRequest(messages: messages(system: systemPrompt(system), user: user), stream: true)
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        try await validate(streamingResponse: response, bytes: bytes)

        var raw = ""
        var lastFlushed = ""
        var lastFlush = Date.distantPast
        let flushInterval: TimeInterval = 0.05

        // Strip complete `<think>…</think>` pairs, then hide everything from a
        // complete-but-unclosed `<think>` onward (an open block still arriving).
        func stripped() -> String {
            let text = Self.stripThinkTags(raw)
            if let open = text.range(of: "<think>") { return String(text[..<open.lowerBound]) }
            return text
        }
        // LIVE display only: additionally hold back any trailing *partial* prefix of
        // `<think>` (e.g. a half-arrived `<thi`) so the opener never flickers
        // half-rendered. Not used for the final result, where a trailing `<` is real
        // content, not an incomplete tag.
        func displayed() -> String { Self.dropTrailingPartial(of: "<think>", in: stripped()) }
        func flush(force: Bool) {
            let text = displayed()
            guard text != lastFlushed else { return }
            if !force && Date().timeIntervalSince(lastFlush) < flushInterval { return }
            lastFlushed = text
            lastFlush = Date()
            onDelta(text)
        }

        var sawSSE = false   // any `data:` line at all → this really is an SSE stream
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            sawSSE = true
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            if payload.isEmpty { continue }
            guard let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let delta = choices.first?["delta"] as? [String: Any],
                  let chunk = delta["content"] as? String,
                  !chunk.isEmpty
            else { continue }   // role-only / finish / reasoning-only chunks → skip
            raw += chunk
            flush(force: false)
        }
        // A 200 response that wasn't actually SSE (no `data:` lines) means the
        // provider/proxy ignored `stream: true` and returned a one-shot body. Throw
        // so `runStreaming` falls back to `complete()` instead of showing "(empty)".
        guard sawSSE else { throw LLMError.badResponse("Response was not a stream") }
        flush(force: true)
        // Final text: drop a never-closed think block, but keep any trailing `<…`
        // (the stream is done, so it's real content, not an incomplete opener).
        return stripped().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Request building (Flowy's per-provider thinking logic)

    /// Prepend Ollama's `/no_think` directive when reasoning is off (mirrors `complete()`).
    private func systemPrompt(_ system: String) -> String {
        if config.provider == "ollama" && config.reasoningEffort == "none" {
            return "/no_think\n\(system)"
        }
        return system
    }

    private func messages(system: String, user: String) -> [[String: String]] {
        [["role": "system", "content": system], ["role": "user", "content": user]]
    }

    private func buildRequest(messages: [[String: String]], stream: Bool) throws -> URLRequest {
        var body: [String: Any] = [
            "model": config.model,
            "messages": messages,
            "stream": stream,
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

    /// Streaming variant: the body is an SSE byte stream, so on a non-2xx status
    /// we drain it to recover the API's JSON error message before throwing.
    private func validate(streamingResponse response: URLResponse, bytes: URLSession.AsyncBytes) async throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200...299).contains(http.statusCode) else {
            var body = ""
            for try await line in bytes.lines {
                body += line
                if body.count > 300 { break }
            }
            let snippet = body.count > 300 ? String(body.prefix(300)) + "…" : body
            throw LLMError.http(status: http.statusCode, message: snippet)
        }
    }

    /// If `text` ends with a non-empty *partial* prefix of `marker` (e.g. text ends
    /// with `<thi` where marker is `<think>`), drop that trailing fragment. Used so a
    /// `<think>` opener split across SSE chunks never flickers half-rendered. A full
    /// `marker` is left intact here (the caller handles complete tags separately).
    private static func dropTrailingPartial(of marker: String, in text: String) -> String {
        // Longest proper prefix of `marker` (excluding the full marker) that the
        // text ends with → that's an incomplete opener still arriving.
        var prefix = String(marker.dropLast())
        while !prefix.isEmpty {
            if text.hasSuffix(prefix) { return String(text.dropLast(prefix.count)) }
            prefix = String(prefix.dropLast())
        }
        return text
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
