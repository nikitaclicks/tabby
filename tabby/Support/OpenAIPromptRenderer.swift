import Foundation

/// File overview:
/// Renders Tabby's suggestion request into a single-user-message chat completion payload that
/// behaves consistently across models with different chat templates.
///
/// Why a single user message (not system + user):
/// Several popular templates — Gemma 2/3 in particular — reject or silently drop the `system`
/// role. Sending instructions as `system` means those models receive no guidance and respond
/// conversationally. Collapsing everything into one `user` message is portable: GPT-4, Claude,
/// Llama-style instruct models, and Gemma all handle it the same way.
///
/// Why a "completion-style" framing inside a chat message:
/// Chat-tuned models default to *answering* prompts. To get them to *continue* the user's text
/// instead of replying about it, we end the prompt with a labeled section ("Continuation:") that
/// makes the next-token target obvious. This is the same trick that makes chat models usable as
/// completion endpoints in autocomplete tooling.
enum OpenAIPromptRenderer {
    /// The single chat `user` message that carries instructions, context, and the prefix text
    /// in a layout that survives different model chat templates. The prefix text is the very last
    /// content before a `Continuation:` label so the model's next tokens land where we want them.
    static func userMessageContent(for request: SuggestionRequest) -> String {
        var sections: [String] = [
            "You are an inline autocomplete engine for a macOS text field.",
            "Continue the text the user has already typed at the caret position.",
            "Output ONLY the continuation characters that should appear next — no preface, no quotes, no labels, no markdown, no explanation, no chat reply.",
            "Do not repeat or restate the existing text.",
            request.completionLengthInstruction,
            "Match the existing language, tone, casing, and punctuation."
        ]

        if let name = request.userName,
           !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append("")
            sections.append("The user's name is \(name). Use it only if it fits naturally.")
        }

        sections.append("")
        sections.append("Active app: \(request.context.applicationName)")

        if let summary = request.visualContextSummary, !summary.isEmpty {
            sections.append("")
            sections.append("Visible screen context:")
            sections.append(summary)
        }

        if let clipboardContext = request.clipboardContext, !clipboardContext.isEmpty {
            sections.append("")
            sections.append("User's clipboard (use only if directly relevant):")
            sections.append(clipboardContext)
        }

        let prefix = request.prefixText.isEmpty
            ? "(the field is empty — produce a short, natural opener)"
            : request.prefixText

        sections.append("")
        sections.append("Text so far (do not repeat any of this in your answer):")
        sections.append("---")
        sections.append(prefix)
        sections.append("---")
        sections.append("")
        sections.append("Continuation:")

        return sections.joined(separator: "\n")
    }

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

    /// Diagnostics show the exact `user` message the engine sends (the engine no longer uses a
    /// separate `system` role — see file overview).
    static func promptPreview(for request: SuggestionRequest) -> String {
        userMessageContent(for: request)
    }
}
