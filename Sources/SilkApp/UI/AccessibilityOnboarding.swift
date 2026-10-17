import AppKit
import SilkPlatform
import SwiftUI

/// The window that explains and walks through granting Accessibility permission, and watches
/// for the grant: it flips to a confirmation and calls `onGranted` as soon as macOS reports Silk
/// as trusted. Shown on first launch, after a reinstall that invalidated the grant, and when the
/// permission is revoked while Silk runs.
@MainActor
final class AccessibilityOnboarding: NSObject, NSWindowDelegate {
    enum Reason {
        /// Silk can't start yet.
        case firstLaunch
        /// The permission was turned off while Silk was running.
        case revoked
    }

    private let model = OnboardingModel()
    private var window: NSWindow?
    private var pollTimer: Timer?
    private var onGranted: (() -> Void)?

    /// Shows the window and polls until Silk is trusted; then shows the confirmation briefly,
    /// closes and calls `onGranted`.
    func show(reason: Reason, bundleId: String, onGranted: @escaping () -> Void) {
        self.onGranted = onGranted
        model.reason = reason
        model.isGranted = false
        model.appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Silk"
        model.openSettings = { [weak self] in self?.openSettings() }
        model.quit = { NSApp.terminate(nil) }

        // A grant recorded for an older build looks "on" in System Settings but doesn't count;
        // clearing it lets the user grant it again with one switch (AeroSpace does the same).
        if reason == .firstLaunch {
            DispatchQueue.global(qos: .userInitiated).async { AccessibilityPermission.resetGrant(bundleId: bundleId) }
        }

        let window = self.window ?? makeWindow()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
        startPolling()
    }

    var isVisible: Bool { window?.isVisible == true }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }

    // MARK: - Private

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 470),
            // No close button: without the permission there is nothing to fall back to ("Quit" is there)
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: OnboardingView(model: model))
        return window
    }

    private func openSettings() {
        // The system prompt adds Silk to the Accessibility list, so the user only has to flip it on.
        AccessibilityPermission.prompt()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkTrust() }
        }
    }

    private func checkTrust() {
        guard AccessibilityPermission.isTrusted else { return }
        pollTimer?.invalidate()
        pollTimer = nil
        model.isGranted = true
        let granted = onGranted
        onGranted = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.window?.close()
            granted?()
        }
    }
}

@MainActor
private final class OnboardingModel: ObservableObject {
    @Published var reason: AccessibilityOnboarding.Reason = .firstLaunch
    @Published var isGranted = false
    @Published var appName = "Silk"
    var openSettings: () -> Void = {}
    var quit: () -> Void = {}
}

private struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 88, height: 88)
                .padding(.top, 34)

            Text(model.reason == .revoked ? "\(model.appName) lost Accessibility access" : "Allow \(model.appName) to arrange your windows")
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
                .padding(.top, 14)

            Text(model.reason == .revoked
                ? "Window management is paused until the permission is turned back on."
                : "\(model.appName) moves and resizes windows through macOS Accessibility. macOS asks you to allow this once.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
                .padding(.horizontal, 44)

            VStack(alignment: .leading, spacing: 12) {
                Step(number: 1, text: "Click **Open System Settings**.")
                Step(number: 2, text: "Turn on **\(model.appName)** in Privacy & Security → Accessibility.")
                Step(number: 3, text: "\(model.appName) starts by itself — no restart needed.")
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.05)))
            .padding(.horizontal, 32)
            .padding(.top, 22)

            Text("Already on but still waiting? Switch \(model.appName) off and on again — macOS keeps the old permission after an update.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 44)
                .padding(.top, 10)

            StatusRow(isGranted: model.isGranted)
                .padding(.top, 18)

            Spacer(minLength: 16)

            HStack {
                Button("Quit \(model.appName)", action: model.quit)
                Spacer()
                Button("Open System Settings", action: model.openSettings)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isGranted)
            }
            .controlSize(.large)
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
        }
        .frame(width: 520, height: 470)
    }
}

private struct Step: View {
    let number: Int
    let text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.callout.weight(.semibold).monospacedDigit())
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.accentColor))
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct StatusRow: View {
    let isGranted: Bool

    var body: some View {
        HStack(spacing: 8) {
            if isGranted {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Permission granted — starting…")
            } else {
                ProgressView().controlSize(.small)
                Text("Waiting for permission…").foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .animation(.easeOut(duration: 0.2), value: isGranted)
    }
}
