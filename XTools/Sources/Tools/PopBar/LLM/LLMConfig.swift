import Foundation

/// Multi-provider LLM configuration — ported from Flowy's `LlmConfig`. The value
/// of this design is that ONE OpenAI-compatible client serves OpenAI / DeepSeek /
/// Doubao / Qwen / Ollama by varying base URL, model, and a *per-provider*
/// thinking knob — DeepSeek's `deepseek-v4-flash` exposes graded reasoning levels
/// rather than a separate "reasoner" model, so thinking is a level, not a model
/// swap.
struct LLMConfig: Equatable {
    var provider: String      // "deepseek" | "openai" | "doubao" | "alibaba" | "ollama"
    var apiKey: String
    var apiURL: String
    var model: String
    /// "" (provider default) | "none" (off) | "minimal" | "low" | "medium" | "high" | "max"
    var reasoningEffort: String

    static let providers = ["deepseek", "openai", "doubao", "alibaba", "ollama"]

    /// Display name for the provider picker.
    static func displayName(_ provider: String) -> String {
        switch provider {
        case "deepseek": return "DeepSeek"
        case "openai":   return "OpenAI"
        case "doubao":   return "Doubao (Ark)"
        case "alibaba":  return "Qwen (DashScope)"
        case "ollama":   return "Ollama"
        default:         return provider
        }
    }

    /// Default base URL + model per provider (Flowy's defaults; DeepSeek updated
    /// to the current `deepseek-v4-flash` — `deepseek-chat`/`-reasoner` retire
    /// 2026-07-24).
    static func providerDefaults(_ provider: String) -> (apiURL: String, model: String) {
        switch provider {
        case "openai":   return ("https://api.openai.com/v1/chat/completions", "gpt-4o-mini")
        case "doubao":   return ("https://ark.cn-beijing.volces.com/api/v3", "")
        case "deepseek": return ("https://api.deepseek.com", "deepseek-v4-flash")
        case "alibaba":  return ("https://dashscope.aliyuncs.com/compatible-mode/v1", "qwen-plus")
        case "ollama":   return ("http://localhost:11434/api/chat", "qwen2.5:7b")
        default:         return ("https://api.deepseek.com", "deepseek-v4-flash")
        }
    }

    /// Single source of truth for the 思考模式 picker, per provider (Flowy's
    /// table): ordered (stored tag, display label). Qwen on/off; Doubao off + 4
    /// levels; DeepSeek off + High/Max; OpenAI/Ollama graded effort, no off.
    static func thinkingOptions(for provider: String) -> [(tag: String, label: String)] {
        switch provider {
        case "alibaba":
            return [("", "On"), ("none", "Off")]
        case "doubao":
            return [("none", "Off"), ("minimal", "Minimal"), ("low", "Low"),
                    ("medium", "Medium"), ("high", "High")]
        case "deepseek":
            return [("none", "Off"), ("high", "High"), ("max", "Max")]
        default: // openai / ollama
            return [("", "Default"), ("none", "Off"), ("low", "Low"),
                    ("medium", "Medium"), ("high", "High")]
        }
    }

    /// Clamp a stored effort into the provider's valid set: invalid → "none"
    /// where there is an off-switch, else "" (model default).
    static func clampThinking(_ effort: String, for provider: String) -> String {
        let tags = thinkingOptions(for: provider).map(\.tag)
        if tags.contains(effort) { return effort }
        return tags.contains("none") ? "none" : ""
    }
}
