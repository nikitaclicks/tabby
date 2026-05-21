import Foundation

/// File overview:
/// Adapts an OpenAI-compatible Chat Completions HTTP endpoint to Tabby's `SuggestionGenerating`
/// capability. The same engine talks to a local `mlx_lm.server`, an Ollama OpenAI shim,
/// OpenRouter, or any other vendor that ships a `/v1/chat/completions` endpoint.
///
/// Why this file exists:
/// Apple Intelligence and local llama.cpp are both *on-device*. Some users want to point Tabby
/// at a more capable remote model or at a local MLX server they already run. Keeping that
/// network call behind the same `SuggestionGenerating` contract means the rest of the pipeline
/// (coordinator, overlay, inserter) does not need to learn that a network now exists.
///
/// Behavioral notes:
/// - We deliberately do not stream. The current `SuggestionGenerating` contract returns one
///   string, and inline completions are short (tens of tokens) — round-trip latency dominates,
///   not first-token latency.
/// - The Authorization header is omitted when no API key is configured so local servers without
///   auth (mlx-lm default, Ollama) work out of the box.
/// - Each request gets a fresh `URLSession` so cancellation propagates cleanly through
///   `URLSessionConfiguration` timeouts without sharing connection state across engine switches.
@MainActor
final class OpenAISuggestionEngine {
    private let suggestionSettings: SuggestionSettingsModel
    private let urlSession: URLSession

    init(
        suggestionSettings: SuggestionSettingsModel,
        urlSession: URLSession? = nil
    ) {
        self.suggestionSettings = suggestionSettings

        if let urlSession {
            self.urlSession = urlSession
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            // 15s is generous for a short autocomplete completion; remote providers usually answer
            // in under 2s. Anything longer than this almost certainly means the user's network or
            // local server is in trouble, and a long wait would block the UI debounce window.
            configuration.timeoutIntervalForRequest = 15
            configuration.timeoutIntervalForResource = 20
            self.urlSession = URLSession(configuration: configuration)
        }
    }

    func generateSuggestion(for request: SuggestionRequest) async throws -> SuggestionResult {
        let baseURLString = suggestionSettings.openAIBaseURL
        let model = suggestionSettings.openAIModelName

        guard !model.isEmpty else {
            throw SuggestionClientError.unavailable(
                "OpenAI engine: set a model name in Settings before requesting suggestions."
            )
        }
        guard let endpoint = makeChatCompletionsURL(from: baseURLString) else {
            throw SuggestionClientError.unavailable(
                "OpenAI engine: base URL '\(baseURLString)' is not a valid URL."
            )
        }

        let apiKey = suggestionSettings.openAIAPIKey()
        let requiresKey = suggestionSettings.openAIPreset == .openRouter
        if requiresKey, (apiKey ?? "").isEmpty {
            throw SuggestionClientError.unavailable(
                "OpenAI engine: OpenRouter requires an API key. Add one in Settings."
            )
        }

        let body = makeRequestBody(for: request, model: model)
        let bodyData: Data
        do {
            bodyData = try JSONSerialization.data(withJSONObject: body, options: [])
        } catch {
            throw SuggestionClientError.generationFailed(
                "OpenAI engine: could not encode request body (\(error.localizedDescription))."
            )
        }

        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = bodyData
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        if let apiKey, !apiKey.isEmpty {
            urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        // OpenRouter recommends these for rate-limit accounting and dashboard attribution. They
        // are harmless to other providers, so we always send them.
        urlRequest.setValue("https://tabby.app", forHTTPHeaderField: "HTTP-Referer")
        urlRequest.setValue("Tabby", forHTTPHeaderField: "X-Title")

        let startTime = Date()

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: urlRequest)
        } catch is CancellationError {
            throw SuggestionClientError.cancelled
        } catch let error as URLError where error.code == .cancelled {
            throw SuggestionClientError.cancelled
        } catch {
            throw SuggestionClientError.unavailable(
                "OpenAI engine: network request failed (\(error.localizedDescription))."
            )
        }

        try Task.checkCancellation()

        if let httpResponse = response as? HTTPURLResponse,
           !(200...299).contains(httpResponse.statusCode) {
            let bodyExcerpt = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(240) ?? ""
            let detail = bodyExcerpt.isEmpty ? "no response body" : String(bodyExcerpt)
            if (400...499).contains(httpResponse.statusCode) {
                throw SuggestionClientError.unavailable(
                    "OpenAI engine: server rejected request (\(httpResponse.statusCode)). \(detail)"
                )
            }
            throw SuggestionClientError.generationFailed(
                "OpenAI engine: server error \(httpResponse.statusCode). \(detail)"
            )
        }

        let rawSuggestion: String
        do {
            rawSuggestion = try parseChatCompletion(data: data)
        } catch let error as SuggestionClientError {
            throw error
        } catch {
            throw SuggestionClientError.generationFailed(
                "OpenAI engine: could not decode response (\(error.localizedDescription))."
            )
        }

        let normalizedSuggestion = SuggestionTextNormalizer.normalize(rawSuggestion, for: request)
        return SuggestionResult(
            generation: request.generation,
            rawText: rawSuggestion,
            text: normalizedSuggestion,
            latency: Date().timeIntervalSince(startTime)
        )
    }

    /// HTTP is stateless — there is no backend cache to invalidate. The protocol still requires
    /// a method so the router can fan resets out uniformly.
    func resetCachedGenerationContext() async {}

    // MARK: - Helpers

    /// Joins a configured base URL with the conventional Chat Completions path. We accept
    /// both `…/v1` and `…/v1/` and reject anything we can't parse as a URL so the caller can
    /// surface the error rather than fire a request at a bogus host.
    private func makeChatCompletionsURL(from baseURL: String) -> URL? {
        var trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        // Tolerate users pasting the full endpoint already.
        if trimmed.hasSuffix("/chat/completions") {
            return URL(string: trimmed)
        }
        return URL(string: "\(trimmed)/chat/completions")
    }

    private func makeRequestBody(for request: SuggestionRequest, model: String) -> [String: Any] {
        let systemMessage = OpenAIPromptRenderer.systemMessage(for: request)
        let userMessage = OpenAIPromptRenderer.userMessage(for: request)

        return [
            "model": model,
            "messages": [
                ["role": "system", "content": systemMessage],
                ["role": "user", "content": userMessage]
            ],
            "max_tokens": max(request.maxPredictionTokens, 1),
            "temperature": request.temperature,
            "top_p": request.topP,
            "stream": false
        ]
    }

    private func parseChatCompletion(data: Data) throws -> String {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SuggestionClientError.generationFailed(
                "OpenAI engine: response was not a JSON object."
            )
        }

        // Surface server-reported errors before we look for choices.
        if let errorObject = json["error"] as? [String: Any] {
            let message = errorObject["message"] as? String ?? "Unknown server error."
            throw SuggestionClientError.unavailable("OpenAI engine: \(message)")
        }

        guard let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw SuggestionClientError.generationFailed(
                "OpenAI engine: response missing `choices[0].message.content`."
            )
        }

        return content
    }
}

extension OpenAISuggestionEngine: SuggestionGenerating {}
