import Foundation

/// File overview:
/// Routes visual-context summarization to the right backend based on the user's selected
/// suggestion engine. Apple Intelligence and llama users get llama-summarized OCR; users on
/// the OpenAI-compatible engine skip summarization entirely and pass raw OCR through.
///
/// Why this exists:
/// Upstream Tabby hardwires `LlamaVisualContextSummarizer` for all engines, which means a user
/// on a non-llama backend would need to *also* download a llama model just to get screen
/// context. That's a confusing requirement. The right behavior is to keep summarization
/// behind the same engine boundary the rest of the pipeline already respects.
///
/// Why OpenAI users skip summarization rather than getting an OpenAI-based summary:
/// Inline autocomplete latency budget is tight. Adding a separate `/chat/completions` round
/// trip to summarize before the actual completion request would roughly double the wait. The
/// completion model is more than capable of extracting the relevant signal from a 2000-char
/// raw OCR blob without a pre-summary, so we save the round trip.
@MainActor
final class RoutedVisualContextSummarizer: VisualContextSummarizing {
    private let suggestionSettings: SuggestionSettingsModel
    private let llamaSummarizer: VisualContextSummarizing

    init(
        suggestionSettings: SuggestionSettingsModel,
        llamaSummarizer: VisualContextSummarizing
    ) {
        self.suggestionSettings = suggestionSettings
        self.llamaSummarizer = llamaSummarizer
    }

    func summarize(text: String, applicationName: String) async throws -> String {
        let engine = suggestionSettings.selectedEngine

        switch engine {
        case .openAICompatible:
            // Pass through. `ScreenshotContextGenerator` will use this as the context excerpt
            // directly. Truncation to the configured max happens downstream regardless.
            TabbyDebugOptions.log(
                "[VC] routed summarizer: engine=\(engine.rawValue), skipping summarization"
            )
            return text

        case .appleIntelligence, .llamaOpenSource:
            return try await llamaSummarizer.summarize(text: text, applicationName: applicationName)
        }
    }
}
