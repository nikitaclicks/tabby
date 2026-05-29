import AppKit
import ApplicationServices
import Foundation

/// File overview:
/// Wraps macOS Accessibility APIs behind Swift-friendly helpers for typed values, tree traversal,
/// element identity, and coordinate normalization.
///
/// This file is intentionally the "ugly edge" of the app. Accessibility APIs are Core Foundation
/// APIs, so they use loosely typed `CFTypeRef` values, C functions, and platform quirks that we do
/// not want spread throughout the rest of the codebase.
enum AXHelper {
    private static let knownEditableRoles: Set<String> = [
        kAXTextFieldRole as String,
        kAXTextAreaRole as String,
        "AXSearchField",
        kAXComboBoxRole as String
    ]

    private static let knownReadOnlyRoles: Set<String> = [
        kAXStaticTextRole as String,
        kAXImageRole as String,
        kAXButtonRole as String,
        "AXLink",
        kAXMenuItemRole as String
    ]

    // MARK: - Attribute Reading

    /// Returns the AX attribute names exposed by an element.
    /// These lists let higher-level code feature-detect capabilities instead of assuming that
    /// every app exposes the same Accessibility surface.
    static func attributeNames(on element: AXUIElement) -> [String] {
        var names: CFArray?
        let result = AXUIElementCopyAttributeNames(element, &names)
        guard result == .success, let names else {
            return []
        }

        return names as? [String] ?? []
    }

    /// Returns the parameterized AX attribute names exposed by an element.
    /// Parameterized attributes are queries such as "bounds for this text range".
    static func parameterizedAttributeNames(on element: AXUIElement) -> [String] {
        var names: CFArray?
        let result = AXUIElementCopyParameterizedAttributeNames(element, &names)
        guard result == .success, let names else {
            return []
        }

        return names as? [String] ?? []
    }

    /// Reads a string AX attribute when the underlying value is present and type-compatible.
    static func stringValue(for attribute: CFString, on element: AXUIElement) -> String? {
        guard let value = copyAttributeValue(attribute, on: element) else {
            return nil
        }

        if let string = value as? String {
            return string
        }

        if let attributedString = value as? NSAttributedString {
            return attributedString.string
        }

        return nil
    }

    static func boolValue(for attribute: CFString, on element: AXUIElement) -> Bool? {
        guard let number = copyAttributeValue(attribute, on: element) as? NSNumber else {
            return nil
        }

        return number.boolValue
    }

    /// Converts loosely typed Accessibility values into `AXValue` only after verifying the Core
    /// Foundation type id. This keeps the unsafe CF boundary in one place and avoids force casts in
    /// the higher-level helpers below.
    private static func axValue(from value: AnyObject?) -> AXValue? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }

        return unsafeBitCast(value, to: AXValue.self)
    }

    /// Reads an `AXValue`-backed range attribute such as the current selection.
    static func rangeValue(for attribute: CFString, on element: AXUIElement) -> NSRange? {
        guard let axValue = axValue(from: copyAttributeValue(attribute, on: element)) else { return nil }
        guard AXValueGetType(axValue) == .cfRange else {
            return nil
        }

        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else {
            return nil
        }

        return NSRange(location: range.location, length: range.length)
    }

    /// Reads an `AXValue`-backed rectangle attribute such as `AXFrame`.
    static func rectValue(for attribute: CFString, on element: AXUIElement) -> CGRect? {
        guard let axValue = axValue(from: copyAttributeValue(attribute, on: element)) else { return nil }
        guard AXValueGetType(axValue) == .cgRect else {
            return nil
        }

        var rect = CGRect.zero
        guard AXValueGetValue(axValue, .cgRect, &rect) else {
            return nil
        }

        return rect
    }

    /// Reads a parameterized rectangle attribute such as `AXBoundsForRange`.
    static func parameterizedRectValue(
        for attribute: CFString,
        range: NSRange,
        on element: AXUIElement
    ) -> CGRect? {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let parameter = AXValueCreate(.cfRange, &cfRange) else {
            return nil
        }

        var value: CFTypeRef?
        let result = AXUIElementCopyParameterizedAttributeValue(element, attribute, parameter, &value)
        guard result == .success, let axValue = axValue(from: value) else { return nil }
        guard AXValueGetType(axValue) == .cgRect else {
            return nil
        }

        var rect = CGRect.zero
        guard AXValueGetValue(axValue, .cgRect, &rect) else {
            return nil
        }

        return rect
    }

    /// Some applications (like Chromium and WebKit browsers) do not properly support `AXBoundsForRange`
    /// using `NSRange`. Instead, they use a private, undocumented Accessibility object called `AXTextMarker`.
    ///
    /// To get the caret rect from these apps, we must:
    /// 1. Ask for `AXSelectedTextMarkerRange` (which returns an opaque `AXTextMarkerRange`).
    /// 2. Pass that marker range back to the element using `AXBoundsForTextMarkerRange`.
    ///
    /// This bypasses the need to translate `NSRange` manually and forces the browser to resolve
    /// the physical layout of its own internal selection object.
    static func textMarkerCaretRect(on element: AXUIElement) -> CGRect? {
        // 1. Get the opaque AXTextMarkerRange that represents the current selection/caret.
        let selectedMarkerRangeAttribute = "AXSelectedTextMarkerRange" as CFString
        var markerRangeValue: CFTypeRef?

        var result = AXUIElementCopyAttributeValue(element, selectedMarkerRangeAttribute, &markerRangeValue)
        guard result == .success, let markerRange = markerRangeValue else {
            return nil
        }

        // 2. Ask the element to compute the bounding box for that exact text marker range.
        let boundsForMarkerRangeAttribute = "AXBoundsForTextMarkerRange" as CFString
        var boundsValue: CFTypeRef?

        result = AXUIElementCopyParameterizedAttributeValue(element, boundsForMarkerRangeAttribute, markerRange, &boundsValue)
        guard result == .success, let axBounds = axValue(from: boundsValue) else { return nil }
        guard AXValueGetType(axBounds) == .cgRect else {
            return nil
        }

        var rect = CGRect.zero
        guard AXValueGetValue(axBounds, .cgRect, &rect) else {
            return nil
        }

        return rect
    }

    /// Reads a raw AX attribute value and leaves type interpretation to the caller.
    /// This is the lowest-level helper in the file; the typed helpers above build on top of it.
    static func copyAttributeValue(_ attribute: CFString, on element: AXUIElement) -> AnyObject? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success else {
            return nil
        }

        return value as AnyObject?
    }

    /// Reads a raw parameterized AX attribute with an arbitrary `CFTypeRef` parameter and leaves
    /// type interpretation to the caller. This is the marker-range equivalent of
    /// `copyAttributeValue`: it exists because every typed parameterized helper would otherwise
    /// duplicate the same `AXUIElementCopyParameterizedAttributeValue` boilerplate.
    static func copyParameterizedAttributeValue(
        _ attribute: CFString,
        parameter: CFTypeRef,
        on element: AXUIElement
    ) -> AnyObject? {
        var value: CFTypeRef?
        let result = AXUIElementCopyParameterizedAttributeValue(element, attribute, parameter, &value)
        guard result == .success else {
            return nil
        }

        return value as AnyObject?
    }

    // MARK: - AX Text Markers
    //
    // Chromium and WebKit expose contenteditable editors (Gmail compose, Slack web, Notion,
    // ClickUp chat, Discord web) through `AXTextMarker` / `AXTextMarkerRange` objects rather
    // than through `kAXSelectedTextRangeAttribute`. These markers are opaque `CFTypeRef`
    // values: we never inspect them, we only feed them back into parameterized AX attributes.
    //
    // All readers below feature-detect their attribute via `parameterizedAttributeNames(on:)`
    // so apps that don't implement the marker API degrade to `nil` instead of erroring.

    /// Reads the marker range representing the element's currently selected text or caret.
    /// Returned value is opaque — pass it back into other marker helpers, never inspect it.
    static func selectedTextMarkerRange(on element: AXUIElement) -> CFTypeRef? {
        copyAttributeValue("AXSelectedTextMarkerRange" as CFString, on: element)
    }

    /// Reads the full marker range covering the element's editable region. Equivalent to
    /// "everything from the start of this contenteditable to its end".
    ///
    /// `host` is the element we query the parameterized attribute on. In Chromium web AX the
    /// marker API is implemented on the `AXWebArea` ancestor, not on individual contenteditable
    /// nodes, so callers walk up to a marker-aware host and pass the original focused element
    /// as the parameter. When `host` is nil we default to querying through `element` itself —
    /// the right behavior for native AppKit text views where the element exposes its own markers.
    static func textMarkerRangeForElement(
        _ element: AXUIElement,
        host: AXUIElement? = nil
    ) -> CFTypeRef? {
        let queryTarget = host ?? element
        let parameterized = Set(parameterizedAttributeNames(on: queryTarget))
        guard parameterized.contains("AXTextMarkerRangeForUIElement") else {
            return nil
        }
        return copyParameterizedAttributeValue(
            "AXTextMarkerRangeForUIElement" as CFString,
            parameter: element,
            on: queryTarget
        )
    }

    /// Returns the start (or end) marker of a marker range. Required because the only reliable
    /// way to measure "characters before the selection" is to build a sub-range from the
    /// element-start marker to the selection-start marker and ask AX for its length.
    static func startMarker(of range: CFTypeRef, on element: AXUIElement) -> CFTypeRef? {
        let parameterized = Set(parameterizedAttributeNames(on: element))
        guard parameterized.contains("AXStartTextMarkerForTextMarkerRange") else {
            return nil
        }
        return copyParameterizedAttributeValue(
            "AXStartTextMarkerForTextMarkerRange" as CFString,
            parameter: range,
            on: element
        )
    }

    static func endMarker(of range: CFTypeRef, on element: AXUIElement) -> CFTypeRef? {
        let parameterized = Set(parameterizedAttributeNames(on: element))
        guard parameterized.contains("AXEndTextMarkerForTextMarkerRange") else {
            return nil
        }
        return copyParameterizedAttributeValue(
            "AXEndTextMarkerForTextMarkerRange" as CFString,
            parameter: range,
            on: element
        )
    }

    /// Builds a marker range that spans two markers regardless of their order. WebKit allows
    /// backwards selections (caret-anchor before drag-anchor); using the "unordered" variant
    /// normalizes the result so the resulting range is always start ≤ end.
    static func markerRange(
        between start: CFTypeRef,
        and end: CFTypeRef,
        on element: AXUIElement
    ) -> CFTypeRef? {
        let parameterized = Set(parameterizedAttributeNames(on: element))
        guard parameterized.contains("AXTextMarkerRangeForUnorderedTextMarkers") else {
            return nil
        }
        let pair = [start, end] as CFArray
        return copyParameterizedAttributeValue(
            "AXTextMarkerRangeForUnorderedTextMarkers" as CFString,
            parameter: pair,
            on: element
        )
    }

    /// Returns the UTF-16 character count of a marker range. Chromium implements this by
    /// walking the range's DOM nodes; on large pages it can be measurably slow, so callers
    /// should only invoke it on focus change rather than on every poll tick.
    static func lengthForMarkerRange(_ range: CFTypeRef, on element: AXUIElement) -> Int? {
        let parameterized = Set(parameterizedAttributeNames(on: element))
        guard parameterized.contains("AXLengthForTextMarkerRange") else {
            return nil
        }
        let value = copyParameterizedAttributeValue(
            "AXLengthForTextMarkerRange" as CFString,
            parameter: range,
            on: element
        )
        return (value as? NSNumber)?.intValue
    }

    /// Returns the plain-text content of a marker range. Callers should bound the marker range
    /// to a window around the caret before reading on large documents (an entire Gmail thread
    /// or Notion doc otherwise stalls the poll cadence).
    static func stringForMarkerRange(_ range: CFTypeRef, on element: AXUIElement) -> String? {
        let parameterized = Set(parameterizedAttributeNames(on: element))
        guard parameterized.contains("AXStringForTextMarkerRange") else {
            return nil
        }
        let value = copyParameterizedAttributeValue(
            "AXStringForTextMarkerRange" as CFString,
            parameter: range,
            on: element
        )
        if let string = value as? String {
            return string
        }
        if let attributed = value as? NSAttributedString {
            return attributed.string
        }
        return nil
    }

    // MARK: - Tree Traversal

    /// Returns the currently focused UI element from the system-wide AX object.
    /// Filters out elements owned by our own process so Tabby's borderless overlay panels
    /// (SwiftUI hosting views) can never be picked up as the focus target.
    static func focusedElement() -> AXUIElement? {
        let systemWideElement = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            systemWideElement, kAXFocusedUIElementAttribute as CFString, &value
        )
        guard result == .success, let element = value else {
            return nil
        }

        guard CFGetTypeID(element) == AXUIElementGetTypeID() else {
            return nil
        }

        // `AXUIElement` is a Core Foundation type, not a normal Swift class.
        // `unsafeBitCast` is appropriate here because we already verified the runtime type id.
        let axElement = unsafeBitCast(element, to: AXUIElement.self)

        // Filter Tabby's own AX elements. Without this, the overlay panel Tabby renders on top
        // of the target app can be reported as the system-wide focused element, which would
        // make focus tracking constantly land in our own SwiftUI subtree.
        var elementPID: pid_t = 0
        AXUIElementGetPid(axElement, &elementPID)
        if elementPID == ProcessInfo.processInfo.processIdentifier {
            return nil
        }

        return axElement
    }

    /// Returns the focused UI element via an application-scoped query against `pid`.
    ///
    /// This is a fallback for the system-wide query returning nil. Chromium browsers do this for
    /// web content hosted in an iframe (Gmail's compose box, other embedded editors): the
    /// system-wide `kAXFocusedUIElementAttribute` resolves to nothing, but the browser's own
    /// application AX element still reports the focused web node (typically carrying the
    /// renderer's PID). Filters Tabby's own elements for the same reason as `focusedElement()`.
    static func focusedElement(forApplicationPID pid: pid_t) -> AXUIElement? {
        guard pid > 0 else {
            return nil
        }

        let appElement = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            appElement, kAXFocusedUIElementAttribute as CFString, &value
        )
        guard result == .success, let element = value,
              CFGetTypeID(element) == AXUIElementGetTypeID() else {
            return nil
        }

        let axElement = unsafeBitCast(element, to: AXUIElement.self)

        var elementPID: pid_t = 0
        AXUIElementGetPid(axElement, &elementPID)
        if elementPID == ProcessInfo.processInfo.processIdentifier {
            return nil
        }

        return axElement
    }

    /// Returns the deepest AX element at a global screen point via hit-testing.
    ///
    /// This is the one query that crosses Chromium's out-of-process-iframe boundary: the focused
    /// node of an OOPIF (Gmail's compose box) isn't reachable through any focused-element
    /// attribute, but `AXUIElementCopyElementAtPosition` resolves it because the window server
    /// knows the on-screen geometry across processes — the same mechanism Accessibility Inspector
    /// uses when you point at an element. `point` must be in top-left global coordinates (what
    /// `CGEvent.location` returns). Filters Tabby's own elements for the usual reason.
    static func elementAtPosition(_ point: CGPoint) -> AXUIElement? {
        let systemWideElement = AXUIElementCreateSystemWide()
        var value: AXUIElement?
        let result = AXUIElementCopyElementAtPosition(
            systemWideElement, Float(point.x), Float(point.y), &value
        )
        guard result == .success, let element = value else {
            return nil
        }

        var elementPID: pid_t = 0
        AXUIElementGetPid(element, &elementPID)
        if elementPID == ProcessInfo.processInfo.processIdentifier {
            return nil
        }

        return element
    }

    /// Returns the parent AX node when the current element exposes one.
    static func parentElement(of element: AXUIElement) -> AXUIElement? {
        guard let value = copyAttributeValue(kAXParentAttribute as CFString, on: element) else {
            return nil
        }

        guard CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }

        // Same Core Foundation bridging rule as `focusedElement()`.
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    /// Returns the immediate AX children for the current element.
    /// The result may be empty either because the node has no children or because the host app
    /// simply does not expose them through Accessibility.
    ///
    /// Chrome's renderer windows for web tabs expose their AX children under the non-standard
    /// `AXChildrenInNavigationOrder` attribute rather than `AXChildren`. We try the standard
    /// attribute first (the common case for native apps and most web elements) and fall back to
    /// the navigation-order variant when it returns empty — that's the only path that surfaces
    /// the actual web AX subtree inside Chrome's renderer.
    static func childElements(of element: AXUIElement) -> [AXUIElement] {
        let primary = readElementArray(attribute: kAXChildrenAttribute, on: element)
        if !primary.isEmpty {
            return primary
        }
        return readElementArray(attribute: "AXChildrenInNavigationOrder", on: element)
    }

    private static func readElementArray(attribute: String, on element: AXUIElement) -> [AXUIElement] {
        guard let values = copyAttributeValue(attribute as CFString, on: element) as? [AnyObject] else {
            return []
        }
        return values.compactMap { value in
            guard CFGetTypeID(value) == AXUIElementGetTypeID() else {
                return nil
            }
            return unsafeBitCast(value, to: AXUIElement.self)
        }
    }

    static func elementIdentity(for element: AXUIElement) -> String {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        return "\(pid)-\(CFHash(element))"
    }

    /// Builds a stable identifier for an AX element by combining bundle identity and AX identity.
    static func elementIdentifier(for element: AXUIElement, bundleIdentifier: String) -> String {
        "\(bundleIdentifier)-\(elementIdentity(for: element))"
    }

    // MARK: - Editability Heuristics

    static func editabilityHintScore(role: String, explicitEditableFlag: Bool?) -> Int {
        var score = 0

        if explicitEditableFlag == true {
            score += 10
        }

        if isKnownEditableRole(role) {
            score += 1
        }

        return score
    }

    /// A strong editability signal is what separates a real input target from display text that merely exposes AX metadata.
    static func hasStrongEditabilitySignal(role: String, explicitEditableFlag: Bool?) -> Bool {
        explicitEditableFlag == true || isKnownEditableRole(role)
    }

    static func isKnownEditableRole(_ role: String) -> Bool {
        knownEditableRoles.contains(role)
    }

    static func isKnownReadOnlyRole(_ role: String) -> Bool {
        knownReadOnlyRoles.contains(role)
    }

    // MARK: - Coordinate Conversion

    /// Converts raw Accessibility coordinates into global AppKit points via a simple Y-flip.
    /// Use this for element-level rects (AXFrame) that are reliably in Cocoa points.
    /// For text-range rects (BoundsForRange, TextMarker), use `validatedCocoaTextRect` instead.
    static func cocoaRect(fromAccessibilityRect rect: CGRect) -> CGRect {
        guard !rect.isNull, rect != .zero else {
            return rect
        }

        let desktopBounds = desktopUnionFrame()
        guard !desktopBounds.isNull else {
            return rect
        }

        return CGRect(
            x: rect.origin.x,
            y: desktopBounds.maxY - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )
    }

    /// Converts a text-range AX rect to Cocoa coordinates, using the element's AXFrame (already
    /// in Cocoa coordinates) as a ground-truth anchor to detect whether pixel-to-point scaling
    /// is needed. This replaces the old bundle-ID heuristic with empirical geometric validation:
    ///   1. Y-flip the raw rect (no scaling) and check if it lands inside the anchor.
    ///   2. If not, divide by the Retina backing scale factor, Y-flip, and recheck.
    ///   3. Whichever version falls near the anchor wins. Falls back to unscaled if neither fits.
    static func validatedCocoaTextRect(
        fromAccessibilityRect textRect: CGRect,
        anchorFrame cocoaAnchorFrame: CGRect?
    ) -> CGRect {
        guard !textRect.isNull, textRect != .zero else {
            return textRect
        }

        let desktopBounds = desktopUnionFrame()
        guard !desktopBounds.isNull else {
            return textRect
        }

        // Candidate A: plain Y-flip, assuming the AX rect is already in Cocoa points.
        let flipped = CGRect(
            x: textRect.origin.x,
            y: desktopBounds.maxY - textRect.origin.y - textRect.height,
            width: textRect.width,
            height: textRect.height
        )

        guard let anchor = cocoaAnchorFrame, !anchor.isEmpty else {
            // No anchor available — plain Y-flip is the safest default.
            return flipped
        }

        // Generous tolerance so padding, scrolling, and multi-line fields don't cause false negatives.
        let tolerance: CGFloat = 80
        let expandedAnchor = anchor.insetBy(dx: -tolerance, dy: -tolerance)

        if expandedAnchor.contains(CGPoint(x: flipped.midX, y: flipped.midY)) {
            return flipped
        }

        // Candidate B: divide by backing scale factor first (Chromium pixel-space workaround),
        // then Y-flip. Some apps return physical pixels for text ranges on Retina.
        let fallbackScale = NSScreen.main?.backingScaleFactor ?? 2.0
        let scale: CGFloat = NSScreen.screens.first(where: {
            $0.frame.contains(CGPoint(
                x: textRect.origin.x / fallbackScale,
                y: $0.frame.maxY - (textRect.origin.y / fallbackScale)
            ))
        })?.backingScaleFactor ?? fallbackScale

        let scaled = CGRect(
            x: textRect.origin.x / scale,
            y: textRect.origin.y / scale,
            width: textRect.width / scale,
            height: textRect.height / scale
        )
        let scaledFlipped = CGRect(
            x: scaled.origin.x,
            y: desktopBounds.maxY - scaled.origin.y - scaled.height,
            width: scaled.width,
            height: scaled.height
        )

        if expandedAnchor.contains(CGPoint(x: scaledFlipped.midX, y: scaledFlipped.midY)) {
            return scaledFlipped
        }

        // Neither candidate landed near the anchor. Return unscaled as best-effort.
        return flipped
    }

    /// Union of all connected screen frames — used for AX top-left → Cocoa bottom-left conversion.
    private static func desktopUnionFrame() -> CGRect {
        NSScreen.screens
            .map(\.frame)
            .reduce(into: CGRect.null) { $0 = $0.union($1) }
    }
}
