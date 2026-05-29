import AppKit
import ApplicationServices
import Darwin
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
    /// Bundle identifiers of Chromium-based apps we know respond to `AXManualAccessibility`.
    ///
    /// The list is mostly actual browsers. Electron desktop apps (Slack, VS Code, Discord,
    /// Notion, …) are also Chromium and would benefit, but priming them blindly risks surfacing
    /// accessibility behavior the app isn't designed to handle, so we don't add Electron apps
    /// wholesale. `com.clickup.desktop-app` is an intentional exception: it's a first-class
    /// target for Tabby (the user explicitly wants inline autocomplete in the ClickUp desktop
    /// app), and its web AX behaves the same as ClickUp in a browser tab once primed.
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
        "com.thebrowser.Browser",
        "com.clickup.desktop-app"       // ClickUp desktop (Electron) — intentional exception
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
    ///
    /// Also primes the browser's renderer/helper subprocesses. Chromium spawns one helper
    /// process per tab (or per site, depending on the site-isolation policy), and the web AX
    /// tree for a given page lives inside that renderer's PID — not the main browser PID. The
    /// `AXManualAccessibility` attribute we set on the main browser does not automatically
    /// propagate to existing renderer subprocesses, so the system-wide AX query keeps returning
    /// the browser's own elements (the omnibox, the window chrome) instead of reaching into the
    /// web content. Priming each child PID directly is what actually wakes the web AX subtree
    /// up for an already-running browser.
    func primeIfNeeded(application: NSRunningApplication) {
        guard isEnabled else {
            return
        }
        guard let bundleIdentifier = application.bundleIdentifier,
              Self.knownChromiumBundleIdentifiers.contains(bundleIdentifier) else {
            return
        }

        let mainPid = application.processIdentifier
        primePid(mainPid, label: bundleIdentifier)
        primeChildrenIfNeeded(parentPid: mainPid)
    }

    /// Returns whether the given bundle identifier is a Chromium-based browser we know how to
    /// prime. Exposed so callers (focus polling, debug overlays) can mirror our coverage decisions
    /// without having to duplicate the bundle-identifier list.
    static func isChromiumBundle(_ bundleIdentifier: String) -> Bool {
        knownChromiumBundleIdentifiers.contains(bundleIdentifier)
    }

    /// Sets `AXManualAccessibility=true` on a single PID, recording it in the per-session cache.
    /// `label` is just for diagnostics; it disambiguates "main browser" vs "renderer" priming.
    private func primePid(_ pid: pid_t, label: String) {
        guard pid > 0, !primedPIDs.contains(pid) else {
            return
        }

        let appElement = AXUIElementCreateApplication(pid)
        // We don't check the result: Chromium accepts the attribute, older versions may not.
        // Either way, we've done what we can — there's no useful recovery path from a failure.
        AXUIElementSetAttributeValue(appElement, Self.attributeName, kCFBooleanTrue)
        primedPIDs.insert(pid)

        TabbyDebugOptions.log(
            "[ChromiumAX] Primed \(label) pid=\(pid) via AXManualAccessibility"
        )
    }

    /// Primes any not-yet-primed direct child processes of `parentPid`. Cheap to call on every
    /// focus tick: `proc_listchildpids` is a microsecond-scale syscall and the per-PID cache
    /// short-circuits priming we've already done. New tabs that spawn after we've primed will
    /// be picked up on the next poll.
    private func primeChildrenIfNeeded(parentPid: pid_t) {
        for childPid in directChildPids(of: parentPid) {
            primePid(childPid, label: "renderer")
        }
    }

    /// Returns the direct child PIDs of `parentPid` using libproc. Empty on failure — Tabby
    /// continues to work without renderer priming, just less reliably on web content focus.
    private func directChildPids(of parentPid: pid_t) -> [pid_t] {
        let neededBytes = proc_listchildpids(parentPid, nil, 0)
        guard neededBytes > 0 else {
            return []
        }
        // Add headroom in case child count grew between the size query and the actual read.
        let capacity = Int(neededBytes) / MemoryLayout<pid_t>.size + 8
        var buffer = [pid_t](repeating: 0, count: capacity)
        let bytesUsed = buffer.withUnsafeMutableBufferPointer { pointer -> Int32 in
            guard let base = pointer.baseAddress else { return 0 }
            return proc_listchildpids(
                parentPid,
                base,
                Int32(capacity * MemoryLayout<pid_t>.size)
            )
        }
        guard bytesUsed > 0 else {
            return []
        }
        let pidCount = Int(bytesUsed) / MemoryLayout<pid_t>.size
        return buffer.prefix(pidCount).filter { $0 > 0 }
    }
}
