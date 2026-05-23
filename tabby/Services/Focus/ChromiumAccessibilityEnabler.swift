import AppKit
import ApplicationServices
import Foundation

/// File overview:
/// Wakes Chromium-based browsers' web Accessibility implementation by setting the documented
/// `AXManualAccessibility` attribute on the browser's AX application element.
///
/// Why this exists:
/// Chromium lazy-enables its web AX tree only when it detects an assistive technology client.
/// Polling-based AX clients like Tabby don't trigger that detection automatically, so web
/// `<input>`, `<textarea>`, and contenteditable elements show up as `AXUnsupported` and Tabby
/// can't see the caret, selection, or text content. Chromium ships a private (but stable and
/// widely used) attribute that says "yes, treat me as an AT" without requiring the user to
/// launch the browser with `--force-renderer-accessibility` or toggle a flag in
/// `chrome://accessibility/`.
///
/// Setting this attribute is more targeted than the global flag: it engages the same AX path
/// VoiceOver uses, which is far better tested than the `--force-renderer-accessibility` path
/// (that one is known to crash renderers on some pages).
///
/// We prime each browser PID once per app session. The attribute is sticky inside Chromium, so
/// repeated calls would be wasted; tracking PIDs we've seen also handles the case where the user
/// quits and relaunches the browser within the same Tabby session.
@MainActor
final class ChromiumAccessibilityEnabler {
    /// Bundle identifiers of Chromium-based browsers we know respond to `AXManualAccessibility`.
    /// Electron-based desktop apps (Slack, VS Code, Discord, Notion, …) are also Chromium and
    /// would benefit, but priming them blindly risks surfacing accessibility behavior the app
    /// isn't designed to handle. Keeping the list to actual browsers is a conservative default.
    private static let knownChromiumBundleIdentifiers: Set<String> = [
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.google.Chrome.beta",
        "com.google.Chrome.dev",
        "org.chromium.Chromium",
        "com.brave.Browser",
        "com.brave.Browser.beta",
        "com.brave.Browser.nightly",
        "com.microsoft.edgemac",
        "com.microsoft.edgemac.Beta",
        "com.microsoft.edgemac.Dev",
        "com.microsoft.edgemac.Canary",
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera",
        "com.operasoftware.OperaGX",
        "company.thebrowser.Browser",   // Arc
        "company.thebrowser.dia",       // Dia (Arc's successor)
        "com.thebrowser.Browser"
    ]

    private static let attributeName = "AXManualAccessibility" as CFString

    private var primedPIDs: Set<pid_t> = []
    private var isEnabled: Bool = true

    /// Allows the rest of the app (e.g. a Settings toggle) to disable the priming. Existing
    /// primed apps stay primed for the lifetime of the browser process; this only stops Tabby
    /// from priming additional ones.
    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
    }

    /// Primes the given app if it is a known Chromium browser we haven't seen before. Safe to
    /// call on every focus tick: the per-PID cache makes repeated invocations a no-op.
    func primeIfNeeded(application: NSRunningApplication) {
        guard isEnabled else {
            return
        }
        guard let bundleIdentifier = application.bundleIdentifier,
              Self.knownChromiumBundleIdentifiers.contains(bundleIdentifier) else {
            return
        }

        let pid = application.processIdentifier
        guard !primedPIDs.contains(pid) else {
            return
        }

        let appElement = AXUIElementCreateApplication(pid)
        // We don't check the result: Chromium accepts the attribute, older versions may not.
        // Either way, we've done what we can — there's no useful recovery path from a failure.
        AXUIElementSetAttributeValue(appElement, Self.attributeName, kCFBooleanTrue)
        primedPIDs.insert(pid)

        TabbyDebugOptions.log(
            "[ChromiumAX] Primed \(bundleIdentifier) pid=\(pid) via AXManualAccessibility"
        )
    }
}
