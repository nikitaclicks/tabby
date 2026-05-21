import Foundation

/// File overview:
/// Defines the product-facing engine choices for Tabby's autocomplete pipeline.
/// This file exists because "which engine is active?" is a domain concept, not a UI-only detail.
///
/// The important architectural distinction is:
/// - a local GGUF file is a model option inside the llama runtime
/// - Apple Intelligence vs. local llama is an engine choice above the runtime layer
enum SuggestionEngineKind: String, CaseIterable, Equatable, Hashable, Sendable, Identifiable {
    case appleIntelligence
    case llamaOpenSource
    case openAICompatible

    var id: String { rawValue }

    var displayLabel: String {
        switch self {
        case .appleIntelligence:
            return "Apple Intelligence [BETA]"
        case .llamaOpenSource:
            return "Open Source"
        case .openAICompatible:
            return "OpenAI-Compatible API"
        }
    }

    var supportsLocalModelManagement: Bool {
        switch self {
        case .appleIntelligence, .openAICompatible:
            return false
        case .llamaOpenSource:
            return true
        }
    }
}

/// Provider preset for the OpenAI-compatible HTTP engine. The preset drives the default
/// base URL and the Keychain account namespace so users can keep separate keys per provider
/// (e.g. one for OpenRouter, none for a local mlx-lm server).
enum OpenAIPreset: String, CaseIterable, Equatable, Hashable, Sendable, Identifiable {
    case localMLX
    case openRouter
    case custom

    var id: String { rawValue }

    var displayLabel: String {
        switch self {
        case .localMLX:
            return "Local (mlx-lm / Ollama)"
        case .openRouter:
            return "OpenRouter"
        case .custom:
            return "Custom"
        }
    }

    /// Default `Base URL` (without trailing `/chat/completions`) prefilled when the user picks
    /// this preset.
    var defaultBaseURL: String {
        switch self {
        case .localMLX:
            return "http://127.0.0.1:8080/v1"
        case .openRouter:
            return "https://openrouter.ai/api/v1"
        case .custom:
            return ""
        }
    }

    /// Keychain account name. Kept stable per provider so switching presets back and forth
    /// preserves each provider's key without manual re-entry.
    var keychainAccount: String {
        rawValue
    }
}

/// A user-authored app blocklist entry.
///
/// The bundle identifier is the durable identity used by the suggestion pipeline. The display name
/// is saved only so Settings can show a readable list without having to resolve installed
/// applications again on every launch.
struct DisabledApplicationRule: Codable, Equatable, Identifiable, Sendable {
    let bundleIdentifier: String
    let displayName: String

    var id: String { bundleIdentifier }
}

/// A compact snapshot of the autocomplete settings the coordinator actually needs at generation
/// time. Keeping this as a value type makes change detection simple and deterministic.
struct SuggestionSettingsSnapshot: Equatable, Sendable {
    let isGloballyEnabled: Bool
    let disabledAppBundleIdentifiers: Set<String>
    let selectedEngine: SuggestionEngineKind
    let selectedWordCountPreset: SuggestionWordCountPreset
    let isClipboardContextEnabled: Bool
    /// User-authored profile data for Tabby's single instruction-rendered completion prompt.
    /// This travels in the snapshot so generation uses the same value the Settings UI shows.
    let userName: String
    let debounceMilliseconds: Int
    let focusPollIntervalMilliseconds: Int
}
