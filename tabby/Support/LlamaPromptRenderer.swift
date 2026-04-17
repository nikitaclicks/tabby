import Foundation

/// File overview:
/// Renders the single prompt string consumed by the local llama runtime.
///
/// Why this file exists:
/// llama.cpp does not give us a separate "instructions" channel the way Foundation Models does.
/// That means all base behavior, user preferences, and request context must be composed into one
/// prompt string. Keeping that composition isolated here prevents prompt policy from leaking into
/// `SuggestionRequestFactory` or the runtime lifecycle layer.
enum LlamaPromptRenderer {
    static func prompt(
        prefixText: String,
        applicationName: String,
        promptMode: SuggestionPromptMode,
        completionLengthInstruction: String,
        customAIInstructions: String?
    ) -> String {
        switch promptMode {
        case .prefixOnly:
            // Prefix-only is intentionally the old low-overhead path: send only the user's local
            // prefix text. This mode is useful precisely because it avoids extra prompt framing.
            return prefixText
        case .guided:
            return guidedPrompt(
                prefixText: prefixText,
                applicationName: applicationName,
                completionLengthInstruction: completionLengthInstruction,
                customAIInstructions: customAIInstructions
            )
        }
    }

    /// Guided mode keeps a more explicit contract for local models that benefit from stronger task
    /// framing, especially when testing how much custom style guidance the model actually follows.
    private static func guidedPrompt(
        prefixText: String,
        applicationName: String,
        completionLengthInstruction: String,
        customAIInstructions: String?
    ) -> String {
        var sections = [
            "You are an invisible, lightning-fast auto-completion engine running on macOS. Your ONLY job is to predict the exact next sequence of characters or words based on the provided text context.",
            "Rules:",
            "Continue the user's existing text at the caret.",
            "NEVER repeat the text that comes before the cursor.",
            completionLengthInstruction,
            "Infer the context from the input and match the tone perfectly.",
            "Output ONLY the predicted continuation text.",
        ]

        sections.append(contentsOf: CustomAIInstructionFormatter.promptSectionLines(from: customAIInstructions))
        sections.append(contentsOf: [
            "Text before caret:",
            prefixText
        ])

        return sections.joined(separator: "\n")
    }
}
