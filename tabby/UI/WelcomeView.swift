import SwiftUI

/// File overview:
/// Renders the first-run onboarding wizard as a four-step flow:
/// welcome -> permissions -> choose model -> ready.
///
/// The engine and model download screens are merged into one step with progressive disclosure:
/// selecting the open-source engine expands its card to reveal downloadable models inline.
/// Each step earns its screen by teaching one thing or collecting one decision.
struct WelcomeView: View {
    @ObservedObject var permissionManager: PermissionManager
    @ObservedObject var runtimeModel: RuntimeBootstrapModel
    @ObservedObject var modelDownloadManager: ModelDownloadManager
    @ObservedObject var suggestionSettings: SuggestionSettingsModel
    @ObservedObject var foundationModelAvailabilityService: FoundationModelAvailabilityService

    let permissionGuidanceController: PermissionGuidanceController
    let onDismiss: () -> Void

    @State private var step: WelcomeStep = .welcome

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            switch step {
            case .welcome:
                welcomeStep
            case .permissions:
                permissionsStep
            case .chooseModel:
                chooseModelStep
            case .done:
                doneStep
            }

            Spacer(minLength: 0)
        }
        .padding(36)
        .frame(width: 540)
        .background(.ultraThinMaterial)
        .animation(.easeInOut(duration: 0.25), value: step)
    }
}

// MARK: - Steps

private enum WelcomeStep: Int, Comparable {
    case welcome
    case permissions
    case chooseModel
    case done

    static func < (lhs: WelcomeStep, rhs: WelcomeStep) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - Step 1: Welcome

private extension WelcomeView {
    var welcomeStep: some View {
        VStack(spacing: 24) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.regularMaterial)
                    .shadow(color: .black.opacity(0.06), radius: 3, y: 1)

                Image(systemName: "pawprint.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.primary)
            }
            .frame(width: 64, height: 64)

            VStack(spacing: 8) {
                Text("Welcome to tabby")
                    .font(.system(size: 28, weight: .semibold, design: .rounded))

                Text("AI autocomplete that runs entirely on your Mac.")
                    .font(.system(size: 15, design: .rounded))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            WelcomeButton(title: "Get Started") {
                step = .permissions
            }
            .padding(.top, 4)
        }
    }
}

// MARK: - Step 2: Permissions

private extension WelcomeView {
    var permissionsStep: some View {
        WelcomePermissionStepView(
            permissionManager: permissionManager,
            permissionGuidanceController: permissionGuidanceController,
            onBack: { step = .welcome },
            onContinue: { step = .chooseModel }
        )
    }
}

// MARK: - Step 3: Choose Model (combined engine + model)

private extension WelcomeView {
    var chooseModelStep: some View {
        VStack(spacing: 24) {
            VStack(spacing: 8) {
                Text("Choose a Model")
                    .font(.system(size: 24, weight: .semibold, design: .rounded))

                Text("Pick how tabby generates completions.")
                    .font(.system(size: 14, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 10) {
                appleIntelligenceCard
                llamaOpenSourceCard
            }

            WelcomeNavigation(
                canGoBack: false,
                canContinue: canContinueFromModelStep,
                disabledHint: modelStepDisabledHint,
                onBack: { step = .permissions },
                onContinue: { step = .done }
            )
        }
    }

    var appleIntelligenceCard: some View {
        let isSelected = suggestionSettings.selectedEngine == .appleIntelligence
        let isAvailable = foundationModelAvailabilityService.isAvailable

        return EngineCard(
            systemImage: "apple.logo",
            title: "Apple Intelligence",
            subtitle: isAvailable
                ? "Built into macOS. No download needed."
                : "Requires Apple Silicon and macOS 26.",
            isSelected: isSelected && isAvailable,
            isAvailable: isAvailable
        ) {
            suggestionSettings.selectEngine(.appleIntelligence)
        }
    }

    var llamaOpenSourceCard: some View {
        let isSelected = suggestionSettings.selectedEngine == .llamaOpenSource

        return VStack(spacing: 0) {
            EngineCard(
                systemImage: "cpu",
                title: "Open Source",
                subtitle: "Runs a local model. One-time download.",
                isSelected: isSelected,
                isAvailable: true
            ) {
                suggestionSettings.selectEngine(.llamaOpenSource)
            }

            if isSelected {
                VStack(spacing: 0) {
                    Divider()
                        .padding(.horizontal, 18)

                    VStack(spacing: 8) {
                        ForEach(modelDownloadManager.models) { model in
                            CompactModelRow(
                                model: model,
                                state: modelDownloadManager.state(for: model),
                                onDownload: { modelDownloadManager.download(model) }
                            )
                        }

                        HStack(spacing: 12) {
                            Button {
                                modelDownloadManager.openModelsDirectory()
                            } label: {
                                Label("Add Your Own", systemImage: "folder.badge.plus")
                                    .font(.system(size: 12))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)

                            Button {
                                modelDownloadManager.refreshModelStates()
                                runtimeModel.refreshAvailableModels()
                            } label: {
                                Label("Refresh", systemImage: "arrow.clockwise")
                                    .font(.system(size: 12))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        Text("Drop any .gguf model into the folder above.")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(18)
                }
                .background(
                    UnevenRoundedRectangle(
                        topLeadingRadius: 0,
                        bottomLeadingRadius: 16,
                        bottomTrailingRadius: 16,
                        topTrailingRadius: 0,
                        style: .continuous
                    )
                    .fill(.regularMaterial.opacity(0.5))
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.white.opacity(0.08), lineWidth: 0.5)
        )
        .animation(.spring(duration: 0.3), value: isSelected)
    }

    var canContinueFromModelStep: Bool {
        switch suggestionSettings.selectedEngine {
        case .appleIntelligence:
            return foundationModelAvailabilityService.isAvailable
        case .llamaOpenSource:
            return hasAtLeastOneModel
        }
    }

    var modelStepDisabledHint: String {
        switch suggestionSettings.selectedEngine {
        case .appleIntelligence:
            return "Apple Intelligence is not available on this Mac."
        case .llamaOpenSource:
            return "Download at least one model to continue."
        }
    }

    var hasAtLeastOneModel: Bool {
        modelDownloadManager.models.contains { model in
            modelDownloadManager.state(for: model) == .downloaded
        } || !runtimeModel.availableModels.isEmpty
    }
}

// MARK: - Step 4: Done

private extension WelcomeView {
    var doneStep: some View {
        VStack(spacing: 24) {
            ZStack {
                Circle()
                    .fill(.green.opacity(0.12))
                    .shadow(color: .green.opacity(0.08), radius: 8, y: 2)

                Image(systemName: "checkmark")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.green)
            }
            .frame(width: 64, height: 64)

            VStack(spacing: 8) {
                Text("You're all set")
                    .font(.system(size: 28, weight: .semibold, design: .rounded))

                Text("Start typing anywhere.\nPress Tab to accept.")
                    .font(.system(size: 15, design: .rounded))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 6) {
                Image(systemName: "menubar.arrow.up.rectangle")
                    .foregroundStyle(.tertiary)

                Text("Find tabby in your menu bar.")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.tertiary)
            }

            WelcomeButton(title: "Start Using tabby") {
                onDismiss()
            }
            .padding(.top, 4)
        }
    }
}

// MARK: - Engine Card

/// Selectable engine card with glass-material background.
/// When selected, shows an accent-tinted border and checkmark. When unavailable, dims the content.
private struct EngineCard: View {
    let systemImage: String
    let title: String
    let subtitle: String
    let isSelected: Bool
    let isAvailable: Bool
    let action: () -> Void

    private var iconColor: Color {
        if !isAvailable { return .secondary }
        return isSelected ? .accentColor : .primary
    }

    var body: some View {
        Button(action: {
            if isAvailable {
                action()
            }
        }) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isSelected ? AnyShapeStyle(Color.accentColor.opacity(0.12)) : AnyShapeStyle(.quaternary.opacity(0.6)))

                    Image(systemName: systemImage)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(iconColor)
                }
                .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(isAvailable ? .primary : .tertiary)

                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                if isSelected && isAvailable {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(.accentColor)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.regularMaterial)
                    .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(
                        isSelected && isAvailable ? Color.accentColor.opacity(0.4) : Color.white.opacity(0.08),
                        lineWidth: isSelected && isAvailable ? 1.5 : 0.5
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(!isAvailable)
    }
}

// MARK: - Compact Model Row

/// App Store-style model download row shown inside the expanded open-source engine card.
private struct CompactModelRow: View {
    let model: DownloadableRuntimeModel
    let state: ModelDownloadState
    let onDownload: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(model.displayName)
                    .font(.system(size: 13, weight: .medium))

                Text(statusText)
                    .font(.system(size: 11))
                    .foregroundStyle(statusColor)
            }

            Spacer(minLength: 0)

            modelActionButton
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.quaternary.opacity(0.3))
        )
    }

    @ViewBuilder
    private var modelActionButton: some View {
        switch state {
        case .idle:
            Button("Get") { onDownload() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        case .downloading:
            ProgressView()
                .controlSize(.small)
                .frame(width: 40)
        case .downloaded:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.system(size: 16))
        case .failed:
            Button("Retry") { onDownload() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }

    private var statusText: String {
        switch state {
        case .idle: return "Not installed"
        case .downloading: return "Downloading..."
        case .downloaded: return "Installed"
        case .failed: return "Failed"
        }
    }

    private var statusColor: Color {
        switch state {
        case .downloaded: return .green
        case .downloading: return .blue
        case .failed: return .red
        case .idle: return .secondary
        }
    }
}

// MARK: - Shared Components

/// Primary action button used on the welcome and done steps.
struct WelcomeButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }
}

/// Continue navigation bar for middle wizard steps.
/// "Continue" can be disabled with a tooltip hint explaining what's needed.
struct WelcomeNavigation: View {
    var canGoBack: Bool = false
    var canContinue: Bool = true
    var disabledHint: String? = nil
    var onBack: (() -> Void)? = nil
    let onContinue: () -> Void

    var body: some View {
        HStack {
            if canGoBack, let onBack {
                Button("Back") {
                    onBack()
                }
                .controlSize(.large)
            }

            Spacer(minLength: 0)

            Button("Continue") {
                onContinue()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!canContinue)
            .help(canContinue ? "" : (disabledHint ?? ""))
        }
    }
}
