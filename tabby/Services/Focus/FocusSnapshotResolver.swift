import AppKit
import ApplicationServices
import Foundation

/// File overview:
/// Resolves the most usable editable candidate around the current AX focus and materializes a
/// stable `FocusSnapshot`. This keeps AX candidate search and snapshot assembly separate from the
/// polling shell in `FocusTracker`.
@MainActor
struct FocusSnapshotResolver {
    private let geometryResolver: AXTextGeometryResolver

    // MARK: - Debug AX tree dump (temporary — remove after caret placement is fixed)
    /// Set to true to print the AX tree every time focus changes. Check Xcode console.
    private static let dumpAXTree = false
    private static var lastDumpedElementID: String?

    init(geometryResolver: AXTextGeometryResolver? = nil) {
        self.geometryResolver = geometryResolver ?? AXTextGeometryResolver()
    }

    /// Resolves the best editable candidate around the focused AX node and materializes a focus snapshot.
    ///
    /// `focusChangeSequence` is a monotonic counter owned by `FocusTracker`. The resolver threads
    /// it into the resulting `FocusedInputSnapshot` so downstream consumers can detect field
    /// switches even when `CFHash`-based `elementIdentifier` collides across recycled AX nodes.
    func resolveSnapshot(
        focusedElement: AXUIElement,
        application: NSRunningApplication,
        focusChangeSequence: UInt64 = 0
    ) -> FocusSnapshot {
        let applicationName = application.localizedName ?? "Unknown"
        let bundleIdentifier = application.bundleIdentifier ?? "unknown.bundle"
        let focusedRole =
            AXHelper.stringValue(for: kAXRoleAttribute as CFString, on: focusedElement) ?? "Unknown"
        let focusedSubrole = AXHelper.stringValue(
            for: kAXSubroleAttribute as CFString, on: focusedElement)
        let focusedElementIdentifier = AXHelper.elementIdentifier(
            for: focusedElement, bundleIdentifier: bundleIdentifier)

        // Dump once per element change so it doesn't spam on repeated focus/value notifications.
        if Self.dumpAXTree, Self.lastDumpedElementID != focusedElementIdentifier {
            Self.lastDumpedElementID = focusedElementIdentifier
            printAXTreeDump(
                focusedElement: focusedElement, app: applicationName, bundle: bundleIdentifier)
        }

        let candidates = candidateElements(around: focusedElement).map {
            candidateSnapshot(for: $0, bundleIdentifier: bundleIdentifier)
        }
        let resolution = FocusCapabilityResolver.resolve(
            candidates: candidates.map(\.resolverCandidate))
        let selectedCandidate = resolution.bestDiagnosticCandidate.flatMap { candidate in
            candidates.first(where: { $0.elementIdentifier == candidate.elementIdentifier })
        }
        let inspection = FocusInspectionSnapshot(
            focusedElementIdentifier: focusedElementIdentifier,
            focusedRole: focusedRole,
            focusedSubrole: focusedSubrole,
            resolvedElementIdentifier: selectedCandidate?.elementIdentifier,
            resolvedRole: selectedCandidate?.role,
            resolvedSubrole: selectedCandidate?.subrole,
            missingCapabilities: resolution.resolvedCandidate == nil
                ? resolution.missingCapabilities : []
        )

        guard let resolvedCandidate = selectedCandidate,
            resolution.resolvedCandidate != nil
        else {
            // Detailed unsupported logging: most common cause is web rich-text editors mounting
            // their AX subtree late (focus first lands on a wrapper). Log what we saw so we can
            // see whether to search deeper, retry, or accept the editor as unsupported.
            if TabbyDebugOptions.isEnabled {
                var focusedPID: pid_t = 0
                AXUIElementGetPid(focusedElement, &focusedPID)
                let focusedChildCount = AXHelper.childElements(of: focusedElement).count
                let focusedAttrSet = Set(AXHelper.attributeNames(on: focusedElement))
                let focusedParamAttrSet = Set(AXHelper.parameterizedAttributeNames(on: focusedElement))
                let focusedAttrs = focusedAttrSet
                    .filter { $0.hasPrefix("AX") }
                    .sorted()
                    .prefix(25)
                    .joined(separator: ",")
                let focusedParamAttrs = focusedParamAttrSet
                    .filter { $0.hasPrefix("AX") }
                    .sorted()
                    .prefix(15)
                    .joined(separator: ",")
                // Marker-API presence on the focused element AND on the nearest marker host
                // (typically the AXWebArea ancestor). If neither has it, Chrome's web AX is
                // either not primed or this page is in a non-AT-aware iframe.
                let focusedHasSelMarker = focusedAttrSet.contains("AXSelectedTextMarkerRange")
                let markerHost: AXUIElement? = {
                    var current: AXUIElement? = focusedElement
                    var hops = 0
                    while let node = current, hops < 12 {
                        let attrs = Set(AXHelper.attributeNames(on: node))
                        if attrs.contains("AXSelectedTextMarkerRange") {
                            return node
                        }
                        current = AXHelper.parentElement(of: node)
                        hops += 1
                    }
                    return nil
                }()
                let markerHostRole = markerHost.flatMap {
                    AXHelper.stringValue(for: kAXRoleAttribute as CFString, on: $0)
                } ?? "<none>"
                let candidateSummary = candidates.prefix(8).map { snap in
                    let role = snap.resolverCandidate.role
                    let subrole = snap.resolverCandidate.subrole ?? "<nil>"
                    let val = snap.resolverCandidate.hasTextValue ? "value" : "noVal"
                    let sel = snap.resolverCandidate.hasSelectionRange ? "sel" : "noSel"
                    let caret = snap.resolverCandidate.hasCaretBounds ? "caret" : "noCaret"
                    return "\(role)/\(subrole)[\(val) \(sel) \(caret)]"
                }.joined(separator: " | ")
                TabbyDebugOptions.log(
                    "[Focus] UNSUPPORTED focusSeq=\(focusChangeSequence) " +
                    "frontmostApp=\(applicationName) frontmostBundle=\(bundleIdentifier ?? "<nil>") " +
                    "focusedElementPID=\(focusedPID) focusedRole=\(focusedRole) " +
                    "focusedChildCount=\(focusedChildCount) " +
                    "candidateCount=\(candidates.count) reason=\(resolution.unsupportedReason) " +
                    "focusedHasSelMarker=\(focusedHasSelMarker) markerHostRole=\(markerHostRole) " +
                    "focusedAttrs=[\(focusedAttrs)] focusedParamAttrs=[\(focusedParamAttrs)] " +
                    "candidates=\(candidateSummary)"
                )
            }
            return FocusSnapshot(
                applicationName: applicationName,
                bundleIdentifier: bundleIdentifier,
                capability: .unsupported(resolution.unsupportedReason),
                context: nil,
                inspection: inspection
            )
        }

        guard let selection = resolvedCandidate.selection else {
            return FocusSnapshot(
                applicationName: applicationName,
                bundleIdentifier: bundleIdentifier,
                capability: .unsupported("Selection range is unavailable."),
                context: nil,
                inspection: inspection
            )
        }

        guard selection.location >= 0, selection.length >= 0 else {
            return FocusSnapshot(
                applicationName: applicationName,
                bundleIdentifier: bundleIdentifier,
                capability: .unsupported("Selection range is invalid."),
                context: nil,
                inspection: inspection
            )
        }

        let value = resolvedCandidate.textValue ?? ""
        // `NSRange` coming from AX is expressed in UTF-16 code units, which is why the code below
        // uses `NSString` instead of slicing a native Swift `String` directly.
        guard selection.location <= value.utf16.count else {
            return FocusSnapshot(
                applicationName: applicationName,
                bundleIdentifier: bundleIdentifier,
                capability: .unsupported("Selection range exceeds the current field value."),
                context: nil,
                inspection: inspection
            )
        }

        // The input target and the geometry source don't need to be the same element.
        // Native AppKit apps give exact caret rects on the input target itself. But Chrome
        // nests precise geometry on deep AXStaticText leaf nodes while the parent text entry
        // area only produces a coarse AXFrame estimate. When the primary candidate's geometry
        // is weak, search deeper for a leaf with exact caret data.
        let caretRect: CGRect
        let caretSource: String
        let caretQuality: CaretGeometryQuality
        let observedCharWidth: CGFloat?
        if let primary = resolvedCandidate.caretRect,
            resolvedCandidate.caretQuality == .exact || resolvedCandidate.caretQuality == .derived {
            caretRect = primary
            caretSource = "\(resolvedCandidate.caretQuality!.label) primary"
            caretQuality = resolvedCandidate.caretQuality!
            observedCharWidth = resolvedCandidate.observedCharWidth
        } else if let deepResult = resolveDeepGeometrySource(
            focusedElement: focusedElement,
            resolvedElement: resolvedCandidate.element,
            cocoaAnchorFrame: resolvedCandidate.inputFrameRect
        ) {
            caretRect = deepResult.rect
            caretSource = "\(deepResult.quality.label) deep"
            caretQuality = deepResult.quality
            observedCharWidth = deepResult.observedCharWidth
        } else if let primary = resolvedCandidate.caretRect {
            caretRect = primary
            caretSource = "\(resolvedCandidate.caretQuality?.label ?? "unknown") primary-fallback"
            caretQuality = resolvedCandidate.caretQuality ?? .estimated
            observedCharWidth = resolvedCandidate.observedCharWidth
        } else {
            return FocusSnapshot(
                applicationName: applicationName,
                bundleIdentifier: bundleIdentifier,
                capability: .unsupported("Caret bounds are unavailable."),
                context: nil,
                inspection: inspection
            )
        }

        let nsValue = value as NSString
        let safeSelectionLocation = min(selection.location, nsValue.length)
        let trailingStart = min(selection.location + selection.length, nsValue.length)
        let context = FocusedInputSnapshot(
            applicationName: applicationName,
            bundleIdentifier: bundleIdentifier,
            processIdentifier: Int32(application.processIdentifier),
            elementIdentifier: resolvedCandidate.elementIdentifier,
            role: resolvedCandidate.role,
            subrole: resolvedCandidate.subrole,
            caretRect: caretRect,
            inputFrameRect: resolvedCandidate.inputFrameRect,
            caretSource: caretSource,
            caretQuality: caretQuality,
            observedCharWidth: observedCharWidth,
            precedingText: nsValue.substring(to: safeSelectionLocation),
            trailingText: nsValue.substring(from: trailingStart),
            selection: selection,
            isSecure: resolvedCandidate.isSecure,
            focusChangeSequence: focusChangeSequence
        )

        if resolvedCandidate.isSecure {
            return FocusSnapshot(
                applicationName: applicationName,
                bundleIdentifier: bundleIdentifier,
                capability: .blocked("Secure text input is active."),
                context: context,
                inspection: inspection
            )
        }

        if selection.length > 0 {
            return FocusSnapshot(
                applicationName: applicationName,
                bundleIdentifier: bundleIdentifier,
                capability: .blocked("Text is currently selected."),
                context: context,
                inspection: inspection
            )
        }

        return FocusSnapshot(
            applicationName: applicationName,
            bundleIdentifier: bundleIdentifier,
            capability: .supported,
            context: context,
            inspection: inspection
        )
    }

    private func candidateElements(around focusedElement: AXUIElement) -> [AXUIElement] {
        var ordered: [AXUIElement] = []
        var seen = Set<String>()

        func append(_ element: AXUIElement?) {
            guard let element else {
                return
            }

            let identity = AXHelper.elementIdentity(for: element)
            guard seen.insert(identity).inserted else {
                return
            }

            ordered.append(element)
        }

        append(focusedElement)

        var ancestors: [AXUIElement] = []
        var currentElement = focusedElement
        for _ in 0..<2 {
            guard let parent = AXHelper.parentElement(of: currentElement) else {
                break
            }

            ancestors.append(parent)
            append(parent)
            currentElement = parent
        }

        // The heuristic search order is:
        // 1. focused node
        // 2. a couple of ancestors
        // 3. children of those nodes
        // 4. bounded BFS into the focused node's descendants (depth ≤ 4, ≤ 80 nodes)
        //
        // The last step exists because some web apps (ClickUp, Notion, others using rich-text
        // editors) focus a wrapper element while the real editable text node sits several levels
        // deeper in the web AX tree. Without this descent, those inputs are reported as
        // Unsupported. The depth/count caps keep this cheap on every focus tick.
        for node in [focusedElement] + ancestors {
            for child in AXHelper.childElements(of: node) {
                append(child)
            }
        }

        bfsDescend(into: focusedElement, append: append)

        return ordered
    }

    /// Bounded BFS into descendants of `root`, calling `append` for each node visited.
    /// Stops once depth or visit count limits are reached so this does not turn into a full
    /// AX-tree walk for huge web pages.
    ///
    /// Depth/visit budget is sized for Chromium contenteditable editors (Notion, ClickUp chat,
    /// Gmail compose, Slack web). Chrome reports focus on a wrapper several levels above the
    /// real editable target: AXWebArea → AXGroup → AXScrollArea → AXGroup → … → AXTextField is
    /// typical. Depth 4 / 80 visits was too shallow for those trees, which left the editable
    /// candidate unreached and reported the field as unsupported. The deep-geometry walker in
    /// this same file uses depth 10 / 200 nodes for an analogous concern.
    private func bfsDescend(
        into root: AXUIElement,
        append: (AXUIElement?) -> Void
    ) {
        let maxDepth = 6
        let maxVisits = 200

        var queue: [(AXUIElement, Int)] = AXHelper.childElements(of: root).map { ($0, 1) }
        var visits = 0

        while !queue.isEmpty, visits < maxVisits {
            let (node, depth) = queue.removeFirst()
            append(node)
            visits += 1

            guard depth < maxDepth else { continue }
            for child in AXHelper.childElements(of: node) {
                queue.append((child, depth + 1))
            }
        }
    }

    /// Runs deep geometry search from the resolved editable candidate first, then falls back to
    /// the raw focused node when those are different branches of the same local AX neighborhood.
    private func resolveDeepGeometrySource(
        focusedElement: AXUIElement,
        resolvedElement: AXUIElement,
        cocoaAnchorFrame: CGRect?
    ) -> CaretGeometryResult? {
        if let result = findDeepGeometrySource(
            from: resolvedElement,
            cocoaAnchorFrame: cocoaAnchorFrame
        ) {
            return result
        }

        guard
            AXHelper.elementIdentity(for: focusedElement)
                != AXHelper.elementIdentity(for: resolvedElement)
        else {
            return nil
        }

        return findDeepGeometrySource(
            from: focusedElement,
            cocoaAnchorFrame: cocoaAnchorFrame
        )
    }

    /// Searches deeper descendants of the focused element for a node with precise caret geometry.
    ///
    /// Chrome's AX tree nests live selection data on deep `AXStaticText` leaf nodes that have
    /// tight per-text-run frames — far more precise than the parent text entry area's AXFrame.
    /// We only read position from these nodes; the input target (where we type) stays unchanged.
    private func findDeepGeometrySource(
        from root: AXUIElement,
        cocoaAnchorFrame: CGRect?
    ) -> CaretGeometryResult? {
        var queue: [(element: AXUIElement, depth: Int)] = [(root, 0)]
        let maxDepth = 10
        let maxNodes = 200
        var visited = 0
        var seen = Set<String>()
        var bestResult: (result: CaretGeometryResult, depth: Int)?

        while !queue.isEmpty, visited < maxNodes {
            let (element, depth) = queue.removeFirst()

            let identity = AXHelper.elementIdentity(for: element)
            guard seen.insert(identity).inserted else { continue }
            visited += 1

            // Look for any node with an active caret (zero-length selection).
            // Don't filter by role — Chrome uses AXStaticText for editable text runs.
            if let range = AXHelper.rangeValue(
                for: kAXSelectedTextRangeAttribute as CFString, on: element
            ), range.length == 0 {
                let paramAttrs = Set(AXHelper.parameterizedAttributeNames(on: element))
                let attrs = Set(AXHelper.attributeNames(on: element))
                let textValue =
                    attrs.contains(kAXValueAttribute as String)
                    ? AXHelper.stringValue(for: kAXValueAttribute as CFString, on: element)
                    : nil
                let result = geometryResolver.resolveCaretRect(
                    for: element,
                    selection: range,
                    supportsBoundsForRange: paramAttrs.contains(
                        kAXBoundsForRangeParameterizedAttribute as String
                    ),
                    supportsFrame: attrs.contains("AXFrame"),
                    cocoaAnchorFrame: cocoaAnchorFrame,
                    textValue: textValue
                )

                if let result, result.quality == .exact || result.quality == .derived {
                    if shouldPreferDeepResult(
                        result,
                        at: depth,
                        over: bestResult
                    ) {
                        bestResult = (result, depth)
                    }
                }
            }

            guard depth < maxDepth else { continue }
            for child in AXHelper.childElements(of: element) {
                queue.append((child, depth + 1))
            }
        }

        return bestResult?.result
    }

    /// Prefers deeper descendants because browser AX wrappers can expose superficially "valid"
    /// geometry on shallow nodes while the real caret anchor lives lower in the text-run leaves.
    private func shouldPreferDeepResult(
        _ candidate: CaretGeometryResult,
        at depth: Int,
        over best: (result: CaretGeometryResult, depth: Int)?
    ) -> Bool {
        guard let best else {
            return true
        }

        if depth != best.depth {
            return depth > best.depth
        }

        return deepResultQualityScore(candidate.quality)
            > deepResultQualityScore(best.result.quality)
    }

    private func deepResultQualityScore(_ quality: CaretGeometryQuality) -> Int {
        switch quality {
        case .exact:
            return 2
        case .derived:
            return 1
        case .estimated:
            return 0
        }
    }

    /// Extracts the AX properties Tabby needs from one candidate element near the current focus.
    private func candidateSnapshot(for element: AXUIElement, bundleIdentifier: String)
        -> AXFocusCandidate {
        let role = AXHelper.stringValue(for: kAXRoleAttribute as CFString, on: element) ?? "Unknown"
        let subrole = AXHelper.stringValue(for: kAXSubroleAttribute as CFString, on: element)
        let supportedAttributes = Set(AXHelper.attributeNames(on: element))
        let supportedParameterizedAttributes = Set(
            AXHelper.parameterizedAttributeNames(on: element))
        let explicitEditableFlag =
            supportedAttributes.contains("AXEditable")
            ? AXHelper.boolValue(for: "AXEditable" as CFString, on: element)
            : nil
        let rawTextValue =
            supportedAttributes.contains(kAXValueAttribute as String)
            ? AXHelper.stringValue(for: kAXValueAttribute as CFString, on: element)
            : nil
        // Chrome's web AX (and a few native apps) returns the field's placeholder string as
        // `kAXValueAttribute` when the field is empty. Treating that as user-typed text makes
        // Tabby ask the completion model to "continue" the placeholder (e.g. "Write to Hierarchy
        // Squad…" → model suggests "/help"). Detect this by comparing against the explicit
        // placeholder attribute and zeroing the value when they match.
        let placeholderValue =
            supportedAttributes.contains("AXPlaceholderValue")
            ? AXHelper.stringValue(for: "AXPlaceholderValue" as CFString, on: element)
            : nil
        let nativeSelection =
            supportedAttributes.contains(kAXSelectedTextRangeAttribute as String)
            ? AXHelper.rangeValue(for: kAXSelectedTextRangeAttribute as CFString, on: element)
            : nil

        // Chromium contenteditable editors (Gmail compose, Slack web, Notion, ClickUp chat,
        // Discord web) don't expose `kAXSelectedTextRangeAttribute`. Their selection state
        // lives in the opaque `AXTextMarker` API, and `kAXValueAttribute` either omits the
        // editable text or returns the placeholder. When the native NSRange selection is
        // missing, derive both the selection offset and the surrounding text via marker math.
        // The result feeds the existing capability resolver (which accepts any candidate with
        // value + selection + caret as "observably editable"), so no schema change is needed.
        let markerSynthesis: MarkerSelectionSynthesis? =
            nativeSelection == nil
            ? synthesizeMarkerBasedSelection(element: element)
            : nil

        let textValue: String?
        if let synthesis = markerSynthesis {
            textValue = synthesis.text
            TabbyDebugOptions.log(
                "[Focus] CHROME-CONTENTEDITABLE role=\(role) " +
                "selectionLoc=\(synthesis.range.location) selectionLen=\(synthesis.range.length) " +
                "textChars=\(synthesis.text.count)"
            )
        } else if let raw = rawTextValue,
                  let placeholder = placeholderValue,
                  !placeholder.isEmpty,
                  raw == placeholder {
            textValue = ""
        } else {
            textValue = rawTextValue
        }
        let selection: NSRange? = nativeSelection ?? markerSynthesis?.range
        var inputFrameRect =
            supportedAttributes.contains("AXFrame")
            ? geometryResolver.resolveInputFrameRect(for: element)
            : nil

        if let currentFrame = inputFrameRect {
            var finalWidth = currentFrame.width
            var finalX = currentFrame.minX

            // Optimization: grab the parent container's width if the active element is narrow
            // so we capture the whole input bar context (e.g. Discord/Slack dynamically sized nodes).
            if let parent = AXHelper.parentElement(of: element),
               let parentFrame = AXHelper.rectValue(for: "AXFrame" as CFString, on: parent) {
                let parentCocoa = AXHelper.cocoaRect(fromAccessibilityRect: parentFrame)
                if parentCocoa.width > finalWidth {
                    finalWidth = parentCocoa.width
                    finalX = parentCocoa.minX
                }
            }

            // Enforce a minimum width to ensure we get a decent horizontal slice.
            if finalWidth < 500 {
                finalWidth = max(finalWidth, 500)
            }

            inputFrameRect = CGRect(
                x: finalX,
                y: currentFrame.minY,
                width: finalWidth,
                height: currentFrame.height
            )
        }
        let caretResult = selection.flatMap {
            geometryResolver.resolveCaretRect(
                for: element,
                selection: $0,
                supportsBoundsForRange: supportedParameterizedAttributes.contains(
                    kAXBoundsForRangeParameterizedAttribute as String),
                supportsFrame: supportedAttributes.contains("AXFrame"),
                cocoaAnchorFrame: inputFrameRect,
                textValue: textValue
            )
        }
        let caretRect = caretResult?.rect
        let caretQuality = caretResult?.quality
        let isSecure = isSecureElement(element: element, role: role, subrole: subrole)
        let elementIdentifier = AXHelper.elementIdentifier(
            for: element, bundleIdentifier: bundleIdentifier)
        let resolverCandidate = FocusCapabilityCandidate(
            elementIdentifier: elementIdentifier,
            role: role,
            subrole: subrole,
            editableHintScore: AXHelper.editabilityHintScore(
                role: role, explicitEditableFlag: explicitEditableFlag),
            hasStrongEditabilitySignal: AXHelper.hasStrongEditabilitySignal(
                role: role, explicitEditableFlag: explicitEditableFlag),
            isKnownReadOnlyRole: AXHelper.isKnownReadOnlyRole(role),
            hasTextValue: textValue != nil,
            hasSelectionRange: selection != nil,
            hasCaretBounds: caretRect != nil,
            isSecure: isSecure
        )

        return AXFocusCandidate(
            element: element,
            elementIdentifier: elementIdentifier,
            role: role,
            subrole: subrole,
            textValue: textValue,
            selection: selection,
            caretRect: caretRect,
            caretQuality: caretQuality,
            observedCharWidth: caretResult?.observedCharWidth,
            inputFrameRect: inputFrameRect,
            isSecure: isSecure,
            resolverCandidate: resolverCandidate
        )
    }

    /// Derives an NSRange selection and surrounding text from a Chromium contenteditable's
    /// AX text-marker API. Used when `kAXSelectedTextRangeAttribute` is missing — the typical
    /// case for Gmail, Slack web, Notion, ClickUp chat, and similar web editors.
    ///
    /// In Chromium web AX the marker API is implemented on the `AXWebArea` ancestor, not on
    /// individual contenteditable nodes. So we walk up from the focused element until we find
    /// a host that exposes `AXSelectedTextMarkerRange` + the parameterized marker attributes,
    /// then query everything through that host while parameterizing element-anchored queries
    /// with the original focused element. That keeps `selection.location` element-local even
    /// when the editable is several levels deep inside the web area.
    ///
    /// Math: `selection.location` is the character count of the range from the start of the
    /// element's editable region to the start of the current selection. `selection.length` is
    /// the character count of the selection itself. Both are computed via parameterized
    /// `AXLengthForTextMarkerRange` calls so we don't have to interpret opaque marker objects.
    /// `AXTextMarkerRangeForUnorderedTextMarkers` is used to compose the prefix range — its
    /// "unordered" semantics also normalize backward selections (caret-anchor before drag-anchor).
    ///
    /// The element's text is bounded to a window around the caret (4 KB before, 4 KB after)
    /// so a long Gmail thread or Notion doc doesn't drag its entire content into every focus
    /// snapshot. Downstream prompt sanitizers further trim the prompt; this just keeps focus
    /// snapshots cheap.
    private func synthesizeMarkerBasedSelection(element: AXUIElement) -> MarkerSelectionSynthesis? {
        guard let host = findMarkerHost(startingFrom: element) else {
            return nil
        }

        guard let selectedMarkerRange = AXHelper.selectedTextMarkerRange(on: host),
              let elementRange = AXHelper.textMarkerRangeForElement(element, host: host),
              let elementStartMarker = AXHelper.startMarker(of: elementRange, on: host),
              let selectionStartMarker = AXHelper.startMarker(of: selectedMarkerRange, on: host),
              let prefixRange = AXHelper.markerRange(
                between: elementStartMarker, and: selectionStartMarker, on: host
              ),
              let prefixLength = AXHelper.lengthForMarkerRange(prefixRange, on: host),
              let selectionLength = AXHelper.lengthForMarkerRange(selectedMarkerRange, on: host)
        else {
            return nil
        }

        let fullText = AXHelper.stringForMarkerRange(elementRange, on: host) ?? ""
        let nsText = fullText as NSString
        let globalLocation = max(0, min(prefixLength, nsText.length))

        let preWindow = 4096
        let postWindow = 4096
        let windowStart = max(0, globalLocation - preWindow)
        let windowEnd = min(nsText.length, globalLocation + postWindow)
        let windowedText = nsText.substring(
            with: NSRange(location: windowStart, length: windowEnd - windowStart)
        )
        let localLocation = globalLocation - windowStart

        return MarkerSelectionSynthesis(
            text: windowedText,
            range: NSRange(location: localLocation, length: max(0, selectionLength))
        )
    }

    /// Walks up the ancestor chain looking for the nearest element that exposes the AX text
    /// marker API. In Chromium-based browsers this is the `AXWebArea` for the active tab; in
    /// native apps it's typically the text view itself, but we still walk up because some apps
    /// publish markers only on the document-level element.
    private func findMarkerHost(startingFrom element: AXUIElement) -> AXUIElement? {
        var current: AXUIElement? = element
        var hops = 0
        while let node = current, hops < 12 {
            let attributes = Set(AXHelper.attributeNames(on: node))
            let parameterized = Set(AXHelper.parameterizedAttributeNames(on: node))
            if attributes.contains("AXSelectedTextMarkerRange"),
               parameterized.contains("AXTextMarkerRangeForUIElement"),
               parameterized.contains("AXLengthForTextMarkerRange") {
                return node
            }
            current = AXHelper.parentElement(of: node)
            hops += 1
        }
        return nil
    }

    /// Detects secure inputs so Tabby can intentionally refuse to operate in sensitive fields.
    private func isSecureElement(element: AXUIElement, role: String, subrole: String?) -> Bool {
        let secureMarkers = [
            role.lowercased(),
            subrole?.lowercased() ?? "",
            AXHelper.stringValue(for: kAXDescriptionAttribute as CFString, on: element)?
                .lowercased() ?? "",
            AXHelper.stringValue(for: kAXTitleAttribute as CFString, on: element)?.lowercased()
                ?? ""
        ]

        return secureMarkers.contains { marker in
            marker.contains("secure") || marker.contains("password")
        }
    }

    // MARK: - Debug AX tree dump

    private func printAXTreeDump(focusedElement: AXUIElement, app: String, bundle: String) {
        var out = "\n========== AX TREE DUMP ==========\n"
        out += "App: \(app) (\(bundle))\n\n"

        out += "-- Focused + ancestors --\n"
        var ancestors: [AXUIElement] = [focusedElement]
        var currentElement = focusedElement
        for _ in 0..<3 {
            guard let parent = AXHelper.parentElement(of: currentElement) else { break }
            ancestors.append(parent)
            currentElement = parent
        }
        for (offset, element) in ancestors.enumerated().reversed() {
            let indent = String(repeating: "  ", count: ancestors.count - 1 - offset)
            out += describeNode(element, indent: indent)
        }

        out += "\n-- Children (depth 6) --\n"
        dumpChildrenRecursive(of: focusedElement, into: &out, indent: "", depth: 0)

        out += "========== END DUMP ==========\n"
        print(out)
    }

    private func dumpChildrenRecursive(
        of element: AXUIElement,
        into out: inout String,
        indent: String,
        depth: Int
    ) {
        guard depth < 6 else { return }
        let children = AXHelper.childElements(of: element)
        for (offset, child) in children.prefix(20).enumerated() {
            out += describeNode(child, indent: "\(indent)[\(offset)] ")
            dumpChildrenRecursive(of: child, into: &out, indent: indent + "  ", depth: depth + 1)
        }
        if children.count > 20 {
            out += "\(indent)  ...+\(children.count - 20) more\n"
        }
    }

    private func describeNode(_ element: AXUIElement, indent: String) -> String {
        let role = AXHelper.stringValue(for: kAXRoleAttribute as CFString, on: element) ?? "?"
        let subrole = AXHelper.stringValue(for: kAXSubroleAttribute as CFString, on: element)
        let attributes = Set(AXHelper.attributeNames(on: element))
        let parameterizedAttributes = Set(AXHelper.parameterizedAttributeNames(on: element))

        var summary = "\(indent)\(role)"
        if let subrole { summary += " (\(subrole))" }
        summary += "\n"

        if let frame = AXHelper.rectValue(for: "AXFrame" as CFString, on: element) {
            let cocoa = AXHelper.cocoaRect(fromAccessibilityRect: frame)
            summary += "\(indent)  frame(AX): \(fmt(frame))  frame(cocoa): \(fmt(cocoa))\n"
        }

        if attributes.contains(kAXValueAttribute as String),
            let text = AXHelper.stringValue(for: kAXValueAttribute as CFString, on: element) {
            let previewText = text.count > 80 ? String(text.prefix(80)) + "…" : text
            summary += "\(indent)  value: " +
                "\"\(previewText.replacingOccurrences(of: "\n", with: "\\n"))\" " +
                "(len=\(text.count))\n"
        }

        if let range = AXHelper.rangeValue(for: kAXSelectedTextRangeAttribute as CFString, on: element) {
            summary += "\(indent)  selection: loc=\(range.location) len=\(range.length)\n"

            if parameterizedAttributes.contains(kAXBoundsForRangeParameterizedAttribute as String) {
                let boundsRect = AXHelper.parameterizedRectValue(
                    for: kAXBoundsForRangeParameterizedAttribute as CFString,
                    range: NSRange(location: range.location, length: 0),
                    on: element
                )
                if let boundsRect, !boundsRect.isEmpty {
                    summary += "\(indent)  BoundsForRange(loc,0): \(fmt(boundsRect))\n"
                } else {
                    summary += "\(indent)  BoundsForRange(loc,0): FAILED\n"
                }
            }
        }

        if let markerRect = AXHelper.textMarkerCaretRect(on: element), !markerRect.isEmpty {
            summary += "\(indent)  TextMarkerCaret: \(fmt(markerRect))\n"
        }

        if let isEditable = AXHelper.boolValue(for: "AXEditable" as CFString, on: element) {
            summary += "\(indent)  editable: \(isEditable)\n"
        }

        let childCount = AXHelper.childElements(of: element).count
        if childCount > 0 { summary += "\(indent)  children: \(childCount)\n" }

        return summary
    }

    private func fmt(_ rect: CGRect) -> String {
        String(format: "(%.0f, %.0f, %.0f×%.0f)", rect.origin.x, rect.origin.y, rect.width, rect.height)
    }
}

/// Result of synthesizing a usable text + selection pair from a Chromium contenteditable's
/// opaque AX text-marker state. The text is intentionally windowed around the caret so we don't
/// drag entire Gmail threads or Notion docs through every focus snapshot.
private struct MarkerSelectionSynthesis {
    let text: String
    let range: NSRange
}

/// AX data read from one candidate element near the current focus.
/// This keeps candidate search state local to the resolver instead of leaking it into the tracker.
private struct AXFocusCandidate {
    let element: AXUIElement
    let elementIdentifier: String
    let role: String
    let subrole: String?
    let textValue: String?
    let selection: NSRange?
    let caretRect: CGRect?
    let caretQuality: CaretGeometryQuality?
    let observedCharWidth: CGFloat?
    let inputFrameRect: CGRect?
    let isSecure: Bool
    let resolverCandidate: FocusCapabilityCandidate
}
