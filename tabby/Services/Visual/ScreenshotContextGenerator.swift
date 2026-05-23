import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// File overview:
/// Converts a newly focused input's surrounding screenshot into OCR text for prompt injection.
/// The pipeline is: focused snapshot -> screenshot crop -> Apple OCR -> optional local summary ->
/// bounded visible-context excerpt.
///
/// Keeping capture/OCR/summarization at this boundary gives the suggestion coordinator a small
/// plain-text value instead of exposing raw screenshots or OCR implementation details.

enum ScreenshotContextGenerationError: LocalizedError {
    case unavailable(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let message), .failed(let message):
            return message
        }
    }
}

@MainActor
final class ScreenshotContextGenerator {
    private let screenshotService: WindowScreenshotService
    private let textExtractor: ScreenTextExtractor
    private let summarizer: VisualContextSummarizing?
    private let configuration: VisualContextConfiguration

    init(
        screenshotService: WindowScreenshotService? = nil,
        textExtractor: ScreenTextExtractor? = nil,
        summarizer: VisualContextSummarizing? = nil,
        configuration: VisualContextConfiguration? = nil
    ) {
        let actualConfig = configuration ?? .default
        self.screenshotService = screenshotService ?? WindowScreenshotService()
        self.textExtractor =
            textExtractor
            ?? ScreenTextExtractor(
                maxImageDimension: actualConfig.maxImageDimension,
                maxRecognizedCharacters: actualConfig.maxRecognizedCharacters
            )
        self.summarizer = summarizer
        self.configuration = actualConfig
    }

    /// Captures a compact region around the focused input and returns a bounded text excerpt that
    /// can be injected into the completion prompt.
    func generateContext(
        for context: FocusedInputSnapshot,
        onStatusChange: (@Sendable (VisualContextStatus) async -> Void)? = nil
    ) async throws -> VisualContextExcerpt {
        TabbyDebugOptions.log(
            "[VC] generateContext app=\(context.applicationName) " +
            "bundle=\(context.bundleIdentifier ?? "<nil>") " +
            "role=\(context.role) subrole=\(context.subrole ?? "<nil>") " +
            "inputFrame=\(rectDescription(context.inputFrameRect)) " +
            "caret=\(rectDescription(context.caretRect))"
        )
        await onStatusChange?(.capturing)

        let screenshot: CapturedWindowScreenshot
        do {
            screenshot = try await screenshotService.captureSnapshot(
                around: context,
                snapshotDimension: configuration.snapshotDimension
            )
            TabbyDebugOptions.log(
                "[VC] capture ok title=\(screenshot.windowTitle ?? "<nil>") " +
                "size=\(screenshot.image.width)x\(screenshot.image.height)"
            )
        } catch let error as WindowScreenshotError {
            TabbyDebugOptions.log("[VC] capture FAILED (unavailable): \(error.localizedDescription)")
            throw ScreenshotContextGenerationError.unavailable(error.localizedDescription)
        } catch {
            TabbyDebugOptions.log("[VC] capture FAILED: \(error.localizedDescription)")
            throw ScreenshotContextGenerationError.failed(error.localizedDescription)
        }

        await onStatusChange?(.extractingText)

        let extractedText: String
        do {
            extractedText = try await textExtractor.extractText(from: screenshot.image).text
            TabbyDebugOptions.log("[VC] OCR ok chars=\(extractedText.count)")
        } catch ScreenTextExtractionError.noRecognizedText {
            TabbyDebugOptions.log(
                "[VC] OCR returned no text. windowTitle=\(screenshot.windowTitle ?? "<nil>")"
            )
            guard let windowTitle = screenshot.windowTitle,
                hasMeaningfulSignal(windowTitle)
            else {
                throw ScreenshotContextGenerationError.unavailable(
                    "The screenshot did not contain enough visible text to build prompt context."
                )
            }

            return VisualContextExcerpt(
                text: boundedSummaryText(normalizeRecognizedText(windowTitle))
            )
        } catch let error as ScreenTextExtractionError {
            TabbyDebugOptions.log("[VC] OCR FAILED (unavailable): \(error.localizedDescription)")
            throw ScreenshotContextGenerationError.unavailable(error.localizedDescription)
        } catch {
            TabbyDebugOptions.log("[VC] OCR FAILED: \(error.localizedDescription)")
            throw ScreenshotContextGenerationError.failed(error.localizedDescription)
        }

        let normalizedText = normalizeRecognizedText(extractedText)

        if TabbyDebugOptions.isEnabled {
            saveDebugScreenshot(
                screenshot.image,
                text: extractedText,
                name: sanitizedDebugName(from: context.applicationName)
            )
        }

        guard hasMeaningfulSignal(normalizedText) else {
            TabbyDebugOptions.log(
                "[VC] normalized OCR too short to summarize chars=\(normalizedText.count)"
            )
            throw ScreenshotContextGenerationError.unavailable(
                "The screenshot did not contain enough visible text to build prompt context."
            )
        }

        let generatedContextText: String
        if let summarizer = summarizer {
            await onStatusChange?(.summarizingText)
            do {
                let summarized = try await summarizer.summarize(
                    text: normalizedText,
                    applicationName: context.applicationName
                )
                // Local llama summarizer can legitimately return empty when no model is loaded
                // (user is on a non-llama engine). Falling back to the raw OCR text keeps visual
                // context useful instead of throwing "not enough text" even though we OCR'd plenty.
                if summarized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    TabbyDebugOptions.log(
                        "[VC] summarize returned empty — falling back to raw OCR (chars=\(normalizedText.count))"
                    )
                    generatedContextText = normalizedText
                } else {
                    TabbyDebugOptions.log(
                        "[VC] summarize ok chars=\(summarized.count)"
                    )
                    generatedContextText = summarized
                }
            } catch {
                // Same reasoning: if summarization throws (no llama runtime / no model), prefer
                // raw OCR over giving the user nothing. Better to inject unsummarized context
                // than to silently lose the screenshot we just spent CPU on.
                TabbyDebugOptions.log(
                    "[VC] summarize FAILED, using raw OCR fallback: \(error.localizedDescription)"
                )
                generatedContextText = normalizedText
            }
        } else {
            generatedContextText = normalizedText
        }

        let finalContextText = boundedSummaryText(generatedContextText)
        guard hasMeaningfulSignal(finalContextText) else {
            TabbyDebugOptions.log(
                "[VC] final context empty after summarize+bound. " +
                "rawOCR=\(normalizedText.count) summarized=\(generatedContextText.count) final=\(finalContextText.count)"
            )
            throw ScreenshotContextGenerationError.unavailable(
                "The screenshot did not contain enough visible text to build prompt context."
            )
        }
        TabbyDebugOptions.log("[VC] context ready chars=\(finalContextText.count)")

        return VisualContextExcerpt(
            text: finalContextText
        )
    }

    /// OCR is noisy by nature. We normalize line whitespace, strip short-token noise from UI
    /// chrome, and keep only a bounded excerpt so the summarizer receives meaningful text.
    private func normalizeRecognizedText(_ rawText: String) -> String {
        PromptContextSanitizer.sanitizeOCR(
            rawText,
            maxCharacters: configuration.maxRecognizedCharacters
        )
    }

    /// Applies the final prompt-injection budget after optional summarization.
    ///
    /// `maxRecognizedCharacters` protects the OCR and summarizer input. This separate cap protects
    /// the autocomplete prompt from a verbose model summary or from the raw-OCR fallback path.
    private func boundedSummaryText(_ text: String) -> String {
        PromptContextSanitizer.sanitize(
            text,
            maxCharacters: configuration.maxSummaryCharacters
        )
    }

    /// We reject OCR text that is mostly punctuation or numeric noise because that would hurt
    /// the completion prompt more than help it.
    private func hasMeaningfulSignal(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= configuration.minRecognizedCharacterCount else {
            return false
        }

        let letterCount = trimmed.unicodeScalars.filter(CharacterSet.letters.contains).count
        return letterCount >= 4
    }

    private func saveDebugScreenshot(_ image: CGImage, text: String, name: String) {
        guard let desktopURL = FileManager.default.urls(
            for: .desktopDirectory,
            in: .userDomainMask
        ).first else {
            return
        }

        let url = desktopURL.appendingPathComponent("tabby-debug-screenshots")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss-SSS"
        let timestamp = formatter.string(from: Date())

        let fileURL = url.appendingPathComponent("\(name)_\(timestamp).png")
        let textURL = url.appendingPathComponent("\(name)_\(timestamp).txt")

        if let dest = CGImageDestinationCreateWithURL(
            fileURL as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) {
            CGImageDestinationAddImage(dest, image, nil)
            CGImageDestinationFinalize(dest)

            try? text.write(to: textURL, atomically: true, encoding: .utf8)
        }
    }

    private func rectDescription(_ rect: CGRect?) -> String {
        guard let rect else { return "<nil>" }
        return String(format: "(%.0f,%.0f %.0fx%.0f)", rect.minX, rect.minY, rect.width, rect.height)
    }

    private func sanitizedDebugName(from rawName: String) -> String {
        let allowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let replacement = UnicodeScalar("_")
        let sanitizedScalars = rawName.unicodeScalars.map { scalar in
            allowedCharacters.contains(scalar) ? scalar : replacement
        }
        let sanitizedName = String(String.UnicodeScalarView(sanitizedScalars))
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return sanitizedName.isEmpty ? "unknown-app" : sanitizedName
    }
}
