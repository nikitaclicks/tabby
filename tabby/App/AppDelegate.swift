import AppKit
import Combine

/// File overview:
/// Builds Tabby's dependency graph and starts the long-lived services that power
/// permissions, focus tracking, suggestion generation, overlay rendering, and acceptance.
/// This file is the app's composition root.
///
/// In React terms, this is the top-level container that owns the long-lived stores/services.
/// SwiftUI renders views from these objects, but the view layer does not create or own them.
///
/// App lifecycle callbacks happen on the main thread; marking this type clarifies actor expectations.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let permissionManager: PermissionManager
    let runtimeModel: RuntimeBootstrapModel
    let modelDownloadManager: ModelDownloadManager
    let focusModel: FocusTrackingModel
    let inputMonitor: InputMonitor
    let suggestionCoordinator: SuggestionCoordinator
    let welcomeCoordinator: WelcomeCoordinator

    private let activationIndicatorController: ActivationIndicatorController
    private var cancellables = Set<AnyCancellable>()

    override init() {
        // Build the dependency graph once up front so every scene/view observes the same
        // long-lived objects for the entire app session.
        let permissionManager = PermissionManager()
        let runtimeManager = LlamaRuntimeManager()
        let runtimeModel = RuntimeBootstrapModel(runtimeManager: runtimeManager)
        let modelDownloadManager = ModelDownloadManager()
        let suppressionController = InputSuppressionController()
        let inputMonitor = InputMonitor(
            permissionProvider: { permissionManager.inputMonitoringGranted },
            suppressionController: suppressionController
        )
        let focusModel = FocusTrackingModel(
            pollInterval: 0.25,
            permissionProvider: { permissionManager.accessibilityGranted },
            ignoredBundleIdentifier: Bundle.main.bundleIdentifier
        )
        let welcomeCoordinator = WelcomeCoordinator(
            permissionManager: permissionManager,
            runtimeModel: runtimeModel,
            modelDownloadManager: modelDownloadManager
        )
        let suggestionInserter = SuggestionInserter(suppressionController: suppressionController)
        let overlayController = OverlayController()
        let activationIndicatorController = ActivationIndicatorController()
        let screenshotContextGenerator = ScreenshotContextGenerator(runtimeManager: runtimeManager)
        let visualContextCoordinator = VisualContextCoordinator(
            screenshotContextGenerator: screenshotContextGenerator,
            screenRecordingPermissionProvider: { permissionManager.screenRecordingGranted }
        )
        let suggestionCoordinator = SuggestionCoordinator(
            permissionManager: permissionManager,
            focusModel: focusModel,
            inputMonitor: inputMonitor,
            overlayController: overlayController,
            suggestionInserter: suggestionInserter,
            suggestionEngine: LlamaSuggestionEngine(runtimeManager: runtimeManager),
            visualContextCoordinator: visualContextCoordinator,
            contextBuffer: ContextBuffer(),
            configuration: .standard
        )

        self.permissionManager = permissionManager
        self.runtimeModel = runtimeModel
        self.modelDownloadManager = modelDownloadManager
        self.focusModel = focusModel
        self.inputMonitor = inputMonitor
        self.suggestionCoordinator = suggestionCoordinator
        self.welcomeCoordinator = welcomeCoordinator
        self.activationIndicatorController = activationIndicatorController
        super.init()

        // These closures bridge events across subsystems without forcing those subsystems
        // to know about each other directly.
        runtimeModel.onWillReloadModel = { [weak suggestionCoordinator] in
            suggestionCoordinator?.prepareForRuntimeModelSwitch()
        }

        modelDownloadManager.onModelDirectoryChanged = { [weak runtimeModel] in
            runtimeModel?.refreshAvailableModels()
        }

        // Combine subscriptions keep the app's long-lived services in sync as permission and
        // focus state changes over time.
        permissionManager.$inputMonitoringGranted
            .sink { [weak self] _ in
                self?.inputMonitor.refresh()
            }
            .store(in: &cancellables)

        focusModel.$snapshot
            .sink { [weak self] snapshot in
                self?.updateActivationIndicator(for: snapshot)
            }
            .store(in: &cancellables)

        suggestionCoordinator.$visualContextStatus
            .sink { [weak self] status in
                self?.activationIndicatorController.setVisualContextStatus(status)
            }
            .store(in: &cancellables)
    }

    /// Starts runtime and observer services once AppKit reports that app launch finished.
    func applicationDidFinishLaunching(_ notification: Notification) {
        runtimeModel.startIfNeeded()
        focusModel.start()
        inputMonitor.start()
        suggestionCoordinator.start()
        welcomeCoordinator.presentIfNeeded()
    }

    /// Stops long-lived services before process exit so observers and runtime resources detach cleanly.
    func applicationWillTerminate(_ notification: Notification) {
        activationIndicatorController.hide(reason: "Activation indicator hidden because Tabby is terminating.")
        suggestionCoordinator.stop()
        inputMonitor.stop()
        focusModel.stop()
        runtimeModel.stop()
    }

    /// Mirrors supported-focus state into the small outside-left activation indicator.
    private func updateActivationIndicator(for snapshot: FocusSnapshot) {
        guard case .supported = snapshot.capability,
              let inputFrameRect = snapshot.context?.inputFrameRect
        else {
            activationIndicatorController.hide(reason: "Activation indicator hidden because the current field is not supported.")
            return
        }

        activationIndicatorController.show(at: inputFrameRect)
    }
}
