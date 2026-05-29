import AppKit
import Foundation

/// File overview:
/// Polls the Accessibility tree on a fixed timer and publishes the latest `FocusSnapshot`.
///
/// Polling is intentionally the only focus-change source. AXObserver delivery is inconsistent in
/// several host apps, and a hybrid push/poll design creates ordering ambiguity. A single polling
/// loop gives Tabby predictable eventual consistency: every tick re-reads the current frontmost
/// focused element and repairs stale state within one poll interval.
@MainActor
final class FocusTracker {
    var onSnapshotChange: ((FocusSnapshot) -> Void)?
    var onPoll: ((FocusPollingEvent) -> Void)?

    private(set) var snapshot: FocusSnapshot = .inactive {
        didSet {
            onSnapshotChange?(snapshot)
        }
    }

    private var pollInterval: TimeInterval
    private let permissionProvider: @MainActor () -> Bool
    private let ignoredBundleIdentifier: String?
    private let snapshotResolver: FocusSnapshotResolver
    private let chromiumAccessibilityEnabler: ChromiumAccessibilityEnabler

    private var timer: Timer?
    private var pollSequence = 0
    private var focusChangeSequence: UInt64 = 0
    private var lastFocusedInputSignature: FocusedInputPollingSignature?

    /// Last logged Chromium focus-probe signature, used to deduplicate the debug diagnostic so it
    /// fires once per focus change rather than on every poll tick. Debug builds only.
    private var lastChromiumFocusProbe: String?

    /// The editable web node discovered by cursor hit-testing for a Chromium out-of-process iframe
    /// (e.g. Gmail compose). Cached so the field stays resolved while the user types and moves the
    /// mouse off it; dropped once the node stops reporting `AXFocused = true`.
    private var cachedHitTestElement: AXUIElement?

    init(
        pollInterval: TimeInterval = 0.05,
        permissionProvider: @escaping @MainActor () -> Bool,
        ignoredBundleIdentifier: String?,
        snapshotResolver: FocusSnapshotResolver? = nil,
        chromiumAccessibilityEnabler: ChromiumAccessibilityEnabler? = nil
    ) {
        self.pollInterval = pollInterval
        self.permissionProvider = permissionProvider
        self.ignoredBundleIdentifier = ignoredBundleIdentifier
        // Default resolver construction must happen inside the actor-isolated initializer body.
        // Swift evaluates default parameter expressions before entering the `@MainActor` context.
        self.snapshotResolver = snapshotResolver ?? FocusSnapshotResolver()
        self.chromiumAccessibilityEnabler = chromiumAccessibilityEnabler ?? ChromiumAccessibilityEnabler()
    }

    /// Starts periodic AX polling and immediately captures an initial snapshot.
    func start() {
        guard timer == nil else {
            refreshNow()
            return
        }

        refreshNow()

        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshNow()
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Stops polling while leaving the most recent snapshot available to callers.
    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Restarts the polling timer with a new interval. No-op if the interval hasn't changed.
    func updatePollInterval(_ interval: TimeInterval) {
        guard interval != pollInterval else {
            return
        }

        pollInterval = interval

        // Only restart if a timer is already running.
        guard timer != nil else {
            return
        }

        stop()
        start()
    }

    /// Performs a synchronous snapshot capture outside the normal polling cadence.
    ///
    /// Other subsystems still call this after input or acceptance events because they know a read is
    /// useful immediately. The implementation is still polling-style: no event is trusted as state;
    /// it only triggers another full AX read.
    func refreshNow() {
        pollSequence += 1
        let capture = captureSnapshot()

        if capture.snapshot != snapshot {
            snapshot = capture.snapshot
        }

        onPoll?(
            FocusPollingEvent(
                sequence: pollSequence,
                focusChangeSequence: focusChangeSequence,
                didChangeFocusedInput: capture.didChangeFocusedInput,
                applicationName: capture.snapshot.applicationName,
                capabilitySummary: capture.snapshot.capability.shortLabel,
                occurredAt: Date()
            )
        )
    }

    /// Captures the current frontmost application's focused element and reduces it into a snapshot.
    private func captureSnapshot() -> FocusCaptureResult {
        guard permissionProvider() else {
            return inactiveCapture(
                applicationName: "Accessibility permission missing",
                bundleIdentifier: nil,
                capability: .blocked("Accessibility permission is required.")
            )
        }

        guard let application = NSWorkspace.shared.frontmostApplication else {
            return inactiveCapture(
                applicationName: "No active application",
                bundleIdentifier: nil,
                capability: .unsupported("No active application.")
            )
        }

        if application.bundleIdentifier == ignoredBundleIdentifier {
            return inactiveCapture(
                applicationName: application.localizedName ?? "Tabby",
                bundleIdentifier: application.bundleIdentifier,
                capability: .blocked("Tabby is focused.")
            )
        }

        // Wake up web Accessibility in Chromium-based browsers so web `<input>` and `<textarea>`
        // elements expose role/caret/selection. Self-throttling via the enabler's PID cache, so
        // this is cheap to call on every poll tick.
        chromiumAccessibilityEnabler.primeIfNeeded(application: application)

        // Multi-process apps like Chrome publish their web-content focused element with the
        // renderer's PID, which the system-wide query can return correctly but an app-scoped
        // query on the main browser PID cannot. So we use the system-wide query — `AXHelper`
        // filters Tabby's own elements internally so our overlay panels can't be picked up.
        //
        // Fallback chain for Chromium iframe-embedded editors (Gmail's compose box, etc.) where
        // the focused-element attribute resolves to nil:
        //   1. system-wide focused element (the normal path for everything)
        //   2. app-scoped focused element on the frontmost (browser) process
        //   3. hit-test by cursor position into the web content
        // Step 3 is the out-of-process-iframe case: Gmail's compose box lives in a separate
        // renderer process and Chrome does not surface its focused node through ANY focused-element
        // attribute (system-wide, browser process, or even the renderer's own app element). But
        // `AXUIElementCopyElementAtPosition` DOES reach it — the same hit-testing Accessibility
        // Inspector uses when you point at the element — because the OS resolves geometry across the
        // process boundary. All fallbacks run only when the cheaper query returned nil, so the
        // working path is untouched.
        let resolvedFocusedElement = AXHelper.focusedElement()
            ?? AXHelper.focusedElement(forApplicationPID: application.processIdentifier)
            ?? focusedElementViaHitTest(application: application)

        // Focus-change-gated diagnostic for Chromium apps: when a contenteditable in a Chrome
        // tab (e.g. Gmail's compose iframe) leaves visual context idle, we need to know what the
        // system-wide focused-element query actually returned — the omnibox, a web node, or nil.
        // Deduplicated via `lastChromiumFocusProbe` so repeated identical polls don't spam.
        logChromiumFocusProbeIfNeeded(application: application, focusedElement: resolvedFocusedElement)

        guard let focusedElement = resolvedFocusedElement else {
            return inactiveCapture(
                applicationName: application.localizedName ?? "Unknown",
                bundleIdentifier: application.bundleIdentifier,
                capability: .unsupported("No focused Accessibility element.")
            )
        }

        let firstPassSnapshot = snapshotResolver.resolveSnapshot(
            focusedElement: focusedElement,
            application: application,
            focusChangeSequence: focusChangeSequence
        )

        guard let context = firstPassSnapshot.context else {
            return FocusCaptureResult(
                snapshot: firstPassSnapshot,
                didChangeFocusedInput: clearFocusedInputSignatureIfNeeded()
            )
        }

        let nextSignature = FocusedInputPollingSignature(context: context)
        guard nextSignature != lastFocusedInputSignature else {
            return FocusCaptureResult(snapshot: firstPassSnapshot, didChangeFocusedInput: false)
        }

        lastFocusedInputSignature = nextSignature
        focusChangeSequence += 1

        let finalSnapshot = snapshotResolver.resolveSnapshot(
            focusedElement: focusedElement,
            application: application,
            focusChangeSequence: focusChangeSequence
        )
        return FocusCaptureResult(snapshot: finalSnapshot, didChangeFocusedInput: true)
    }

    /// Last-resort focus discovery for Chromium out-of-process iframes via cursor hit-testing.
    ///
    /// Gmail's compose box runs in a separate renderer process and Chrome exposes its focused node
    /// through NO focused-element attribute — but `AXUIElementCopyElementAtPosition` reaches it
    /// (the same hit-test Accessibility Inspector uses when you point at the element). We hit-test
    /// at the current cursor position; if it lands on an editable web node (or one nested in an
    /// editable container), we use it.
    ///
    /// Because the user moves the mouse away while typing, we cache the discovered element and keep
    /// returning it as long as it still reports `AXFocused = true`. That makes the field stable for
    /// the whole editing session even though the cursor only had to be over it for one poll (right
    /// after the click that focused it). The cache drops the moment the node loses focus.
    ///
    /// Only runs for Chromium-family apps, after the cheaper queries returned nil.
    private func focusedElementViaHitTest(application: NSRunningApplication) -> AXUIElement? {
        guard let bundle = application.bundleIdentifier,
              bundle.contains("Chrome") || bundle.contains("hromium")
                || bundle == "com.clickup.desktop-app" else {
            cachedHitTestElement = nil
            return nil
        }

        // Reuse the cached field while it is still the focused node — survives the mouse moving
        // off it during typing.
        if let cached = cachedHitTestElement {
            if AXHelper.boolValue(for: kAXFocusedAttribute as CFString, on: cached) == true {
                return cached
            }
            cachedHitTestElement = nil
        }

        // `CGEvent.location` is already in the top-left global coordinate space that
        // `AXUIElementCopyElementAtPosition` expects, so no Cocoa Y-flip is needed.
        guard let cursor = CGEvent(source: nil)?.location,
              let hit = AXHelper.elementAtPosition(cursor) else {
            return nil
        }

        // Only accept a hit that is actually an editable text surface (itself or a near ancestor),
        // so pointing at a button or page chrome doesn't get mistaken for a field.
        guard let editable = nearestEditable(from: hit) else {
            return nil
        }

        cachedHitTestElement = editable
        return editable
    }

    /// Returns `element` or the nearest ancestor (within a few hops) that exposes a text-editing
    /// surface — a selection range, marker selection, or a known editable role. Hit-testing often
    /// lands on a leaf `AXStaticText` inside the field; this climbs to the editable container.
    private func nearestEditable(from element: AXUIElement) -> AXUIElement? {
        var current: AXUIElement? = element
        var hops = 0
        while let node = current, hops < 4 {
            let attributes = Set(AXHelper.attributeNames(on: node))
            let hasSelection = attributes.contains(kAXSelectedTextRangeAttribute as String)
                || attributes.contains("AXSelectedTextMarkerRange")
            let role = AXHelper.stringValue(for: kAXRoleAttribute as CFString, on: node) ?? ""
            if hasSelection || AXHelper.isKnownEditableRole(role) {
                return node
            }
            current = AXHelper.parentElement(of: node)
            hops += 1
        }
        return nil
    }

    /// Logs what the system-wide focus query resolved to inside a Chromium app, once per change.
    ///
    /// This is the targeted replacement for the heavy per-candidate probe we removed: it runs at
    /// most a couple of cheap AX reads, only for Chromium frontmost apps, and only emits a line
    /// when the resolved element actually changes. It exists to diagnose Chrome web-content cases
    /// (Gmail compose, other iframe-hosted contenteditables) that leave Tabby idle — telling us
    /// whether focus reached a web node, stayed on the browser chrome, or returned nothing.
    private func logChromiumFocusProbeIfNeeded(
        application: NSRunningApplication,
        focusedElement: AXUIElement?
    ) {
        guard TabbyDebugOptions.isEnabled else {
            return
        }
        guard let bundle = application.bundleIdentifier,
              bundle.contains("Chrome") || bundle.contains("hromium")
                || bundle == "com.clickup.desktop-app" else {
            return
        }

        // Distinguish which query produced the element so we can tell, for the Gmail/iframe case,
        // which fallback (if any) reached web content the system-wide query misses.
        let source: String
        if AXHelper.focusedElement() != nil {
            source = "system-wide"
        } else if AXHelper.focusedElement(forApplicationPID: application.processIdentifier) != nil {
            source = "app-scoped-fallback"
        } else if focusedElement != nil {
            source = "hit-test-fallback"
        } else {
            source = "none"
        }

        let signature: String
        if let focusedElement {
            var pid: pid_t = 0
            AXUIElementGetPid(focusedElement, &pid)
            let role = AXHelper.stringValue(for: kAXRoleAttribute as CFString, on: focusedElement) ?? "<nil>"
            let subrole = AXHelper.stringValue(for: kAXSubroleAttribute as CFString, on: focusedElement) ?? "<nil>"
            let childCount = AXHelper.childElements(of: focusedElement).count
            let hasSelMarker = Set(AXHelper.attributeNames(on: focusedElement))
                .contains("AXSelectedTextMarkerRange")
            signature = "source=\(source) pid=\(pid) role=\(role) subrole=\(subrole) " +
                "children=\(childCount) selMarker=\(hasSelMarker)"
        } else {
            signature = "focusedElement=nil (both system-wide and app-scoped returned nothing)"
        }

        guard signature != lastChromiumFocusProbe else {
            return
        }
        lastChromiumFocusProbe = signature
        TabbyDebugOptions.log(
            "[Focus] CHROME-FOCUS-PROBE app=\(application.localizedName ?? "?") " +
            "bundle=\(application.bundleIdentifier ?? "?") \(signature)"
        )
    }

    private func inactiveCapture(
        applicationName: String,
        bundleIdentifier: String?,
        capability: FocusCapability
    ) -> FocusCaptureResult {
        FocusCaptureResult(
            snapshot: FocusSnapshot(
                applicationName: applicationName,
                bundleIdentifier: bundleIdentifier,
                capability: capability,
                context: nil,
                inspection: nil
            ),
            didChangeFocusedInput: clearFocusedInputSignatureIfNeeded()
        )
    }

    /// Clears the last field signature when polling no longer finds a usable focused input.
    ///
    /// This matters for a later return to the same AX element. Leaving and re-entering a field is a
    /// new focus session for visual context even if the host app reuses the same AX object.
    private func clearFocusedInputSignatureIfNeeded() -> Bool {
        guard lastFocusedInputSignature != nil else {
            return false
        }

        lastFocusedInputSignature = nil
        focusChangeSequence += 1
        return true
    }
}

private struct FocusCaptureResult {
    let snapshot: FocusSnapshot
    let didChangeFocusedInput: Bool
}

/// Stable-enough identity for one focused input as observed by polling.
///
/// Text, selection, and caret position are deliberately excluded. Those can change inside the same
/// field and should not restart the visual-context session. The input frame is preferred over the
/// AX element id because AX identifiers are derived from Core Foundation object identity, which can
/// be recycled by macOS.
private struct FocusedInputPollingSignature: Equatable {
    let bundleIdentifier: String
    let processIdentifier: Int32
    let role: String
    let subrole: String?
    let fieldAnchor: FieldAnchor

    init(context: FocusedInputSnapshot) {
        bundleIdentifier = context.bundleIdentifier
        processIdentifier = context.processIdentifier
        role = context.role
        subrole = context.subrole
        fieldAnchor = FieldAnchor(
            inputFrame: context.inputFrameRect,
            fallbackElementIdentifier: context.elementIdentifier
        )
    }
}

private extension FocusedInputPollingSignature {
    struct FieldAnchor: Equatable {
        let roundedInputFrame: RoundedRect?
        let fallbackElementIdentifier: String?

        init(inputFrame: CGRect?, fallbackElementIdentifier: String) {
            roundedInputFrame = inputFrame.map { RoundedRect(rect: $0) }
            self.fallbackElementIdentifier = roundedInputFrame == nil ? fallbackElementIdentifier : nil
        }
    }

    struct RoundedRect: Equatable {
        let minX: Int
        let minY: Int
        let width: Int
        let height: Int

        init(rect: CGRect) {
            minX = Int(rect.minX.rounded())
            minY = Int(rect.minY.rounded())
            width = Int(rect.width.rounded())
            height = Int(rect.height.rounded())
        }
    }
}
