import Foundation

/// System prompts for the AI actions. Kept in English (the model follows them
/// regardless of UI language); each tells the model to answer in the text's own
/// language and to output only the result, no preamble.
enum Prompts {
    static func system(for transform: AITransform) -> String {
        switch transform {
        case .translate:
            return """
            You are a translation engine. Detect the language of the user's text: \
            if it is Chinese, translate it into natural English; otherwise translate \
            it into natural Simplified Chinese. Output ONLY the translation, with no \
            quotes, labels, or explanation.
            """
        case .polish:
            return """
            You are a writing editor. Rewrite the user's text to be clearer, more \
            fluent and natural, preserving its original language and meaning. Output \
            ONLY the polished text, with no quotes, labels, or explanation.
            """
        case .explain:
            return """
            You are a concise explainer. Explain the meaning of the user's selected \
            text (and any notable terms or context) in 2-4 sentences. Respond in the \
            same language as the text. Output ONLY the explanation.
            """
        }
    }
}
