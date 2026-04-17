import AppKit
import SwiftUI

/// File overview:
/// Renders the onboarding step that teaches users how to grant Tabby's required permissions.
///
/// This view exists as its own file because the permission step now owns more than a plain list of
/// buttons. It coordinates measured source frames for the launch animation, explains the guided
/// flow, and stays subscribed to live permission state. Pulling that complexity out of
/// `WelcomeView` keeps the wizard readable and makes the permission subsystem easier to evolve.
struct WelcomePermissionStepView: View {
    @ObservedObject var permissionManager: PermissionManager

    let permissionGuidanceController: PermissionGuidanceController
    let onBack: () -> Void
    let onContinue: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            WelcomeStepHeader(
                title: "Grant Permissions",
                subtitle: "Tabby needs Accessibility and Input Monitoring before it can read your typing context and accept completions with Tab."
            )

            VStack(alignment: .leading, spacing: 10) {
                Text("Use Guide Me for the required permissions. Tabby opens the right privacy pane and pins a drag helper over the exact list macOS expects.")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(.secondary)

                Text("If System Settings opens behind another window, bring it to the front and the helper will snap into place.")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(.tertiary)
            }

            VStack(spacing: 12) {
                ForEach(TabbyPermissionKind.allCases) { permission in
                    WelcomePermissionGuideCard(
                        permission: permission,
                        granted: permissionManager.isGranted(permission),
                        permissionGuidanceController: permissionGuidanceController
                    )
                }
            }

            WelcomeNavigation(
                canGoBack: true,
                canContinue: permissionManager.requiredPermissionsGranted,
                disabledHint: "Grant Accessibility and Input Monitoring to continue.",
                onBack: onBack,
                onContinue: onContinue
            )
        }
        .onDisappear {
            // The helper is only relevant while this step is on screen. Dismissing here avoids
            // leaving an orphaned overlay floating over System Settings after the user advances.
            permissionGuidanceController.dismiss()
        }
    }
}

/// One permission card inside the onboarding step.
///
/// The card owns its measured button frame because that is view-specific state: the service wants
/// a source rect for the launch animation, but it should not know how SwiftUI laid out the row.
private struct WelcomePermissionGuideCard: View {
    let permission: TabbyPermissionKind
    let granted: Bool
    let permissionGuidanceController: PermissionGuidanceController

    @State private var actionButtonFrame = CGRect.zero

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: granted ? "checkmark.circle.fill" : "hand.tap.fill")
                .font(.system(size: 18))
                .foregroundStyle(granted ? Color.green : Color.accentColor)
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(permission.title)
                        .font(.system(size: 14, weight: .semibold))

                    if !permission.isRequiredForAutocomplete {
                        WelcomePermissionBadge(text: "Optional")
                    }
                }

                Text(permission.onboardingSubtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                if !granted {
                    Text(permission.guidanceHint)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 0)

            if granted {
                WelcomePermissionStatusPill(text: "Granted", color: .green)
            } else {
                Button(actionTitle) {
                    permissionGuidanceController.requestAccess(
                        for: permission,
                        sourceFrameInScreen: actionButtonFrame
                    )
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .background(ScreenFrameReader(frameInScreen: $actionButtonFrame))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.quaternary.opacity(0.5))
        )
    }

    private var actionTitle: String {
        switch permission.guidanceStyle {
        case .guidedOverlay:
            "Guide Me"
        case .settingsOnly:
            "Open Settings"
        }
    }
}

private struct WelcomePermissionBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
    }
}

private struct WelcomePermissionStatusPill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(color.opacity(0.12), in: Capsule())
    }
}

/// SwiftUI wrapper around a tiny AppKit view that reports its bounds in screen coordinates.
///
/// `GeometryReader` knows about local layout, but the permission helper animation needs a global
/// screen rect because the destination overlay lives in a separate `NSPanel`.
private struct ScreenFrameReader: NSViewRepresentable {
    @Binding var frameInScreen: CGRect

    func makeNSView(context: Context) -> ScreenFrameTrackingView {
        let view = ScreenFrameTrackingView()
        view.onFrameChange = { frame in
            frameInScreen = frame
        }
        return view
    }

    func updateNSView(_ nsView: ScreenFrameTrackingView, context: Context) {
        nsView.onFrameChange = { frame in
            frameInScreen = frame
        }
        nsView.reportFrame()
    }
}

private final class ScreenFrameTrackingView: NSView {
    var onFrameChange: ((CGRect) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reportFrame()
    }

    override func layout() {
        super.layout()
        reportFrame()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        reportFrame()
    }

    func reportFrame() {
        guard let window else {
            return
        }

        let frame = window.convertToScreen(convert(bounds, to: nil))
        DispatchQueue.main.async { [onFrameChange] in
            onFrameChange?(frame)
        }
    }
}
