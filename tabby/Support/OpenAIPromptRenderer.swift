import Foundation

/// File overview:
/// Renders Tabby's suggestion request into the two-message shape expected by OpenAI Chat
/// Completions: a `system` message that pins the role and output contract, and a `user` message
/// that carries the prefix-text the model must continue.
///
/// Why this file exists:
/// Local llama runs through a single prompt string and Apple's Foundation Models has its own
/// instructions channel; OpenAI-compatible servers (mlx-lm, OpenRouter, Ollama, etc.) expect a
/// chat message array. Keeping that translation here matches the existing renderer per backend
/// pattern and prevents OpenAI-shaped strings from leaking into `SuggestionRequestFactory`.
enum OpenAIPromptRenderer {
    /// Mirrors `FoundationModelPromptRenderer.sessionInstructions(for:)` so completion behavior
    /// stays consistent across engines that support a separate instructions channel.
    static func systemMessage(for request: SuggestionRequest) -> String {
        var lines = [
            "You are Tabby's inline autocomplete engine for a macOS text field.",
            "Complete the user's existing text at the current caret position.",
            "This is not a chatbot.",
            "Do not answer the user as an assistant or begin a conversation.",
            "Return exactly one continuation fragment.",
            request.completionLengthInstruction,
            "Do not repeat or quote the existing text.",
            "Match the existing tone, language, casing, and punctuation.",
            "Use clipboard context only when it directly helps the inline continuation.",
            "Use plain text only with no labels, bullets, markdown, or explanation."
        ]

        if let name = request.userName, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("User Profile Context:")
            lines.append("The user's name is \(name).")
            lines.append("Use this context only when it fits naturally into the continuation.")
        }

        return lines.joined(separator: "\n")
    }

    /// The user-role payload. Carries the screen/clipboard context and the prefix text the model
    /// must continue. We deliberately keep prefix text last so the model's continuation pivots on
    /// the freshest characters.
    static func userMessage(for request: SuggestionRequest) -> String {
        let prefixText = request.prefixText
        if prefixText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Continue the text at the caret using a short inline completion."
        }

        var sections = [
            "Screen context:",
            "App: \(request.context.applicationName)"
        ]

        if let summary = request.visualContextSummary, !summary.isEmpty {
            sections.append("Screen content:")
            sections.append(summary)
        }

        if let clipboardContext = request.clipboardContext, !clipboardContext.isEmpty {
            sections.append("")
            sections.append("User's clipboard:")
            sections.append(clipboardContext)
        }

        sections.append(contentsOf: [
            "",
            "Text before the caret:",
            prefixText,
            "",
            "Write only the next continuation fragment."
        ])

        return sections.joined(separator: "\n")
    }

    /// Diagnostics need to show both message bodies the OpenAI engine sends. Keeping this here
    /// (rather than in `SuggestionRequestFactory`) mirrors `FoundationModelPromptRenderer` and
    /// keeps backend-specific formatting out of the shared request factory.
    static func promptPreview(for request: SuggestionRequest) -> String {
        [
            "System:",
            systemMessage(for: request),
            "",
            "User:",
            userMessage(for: request)
        ].joined(separator: "\n")
    }
}
