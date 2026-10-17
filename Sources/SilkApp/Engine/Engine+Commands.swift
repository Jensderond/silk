import AppKit
import SilkAnimation
import SilkConfig
import SilkCore
import SilkIPC
import SilkPlatform

// MARK: - Hotkeys

extension Engine {
    /// Registers the active mode's bindings (nothing while disabled).
    func registerHotkeys() {
        let bindings = manager.activeBindings
        hotkeyDescriptors = [:]
        var hotkeyList: [Hotkey] = []
        for (index, binding) in bindings.enumerated() {
            let id = UInt32(index + 1)
            hotkeyDescriptors[id] = binding.descriptor
            hotkeyList.append(Hotkey(id: id, keyCode: binding.chord.keyCode, modifiers: HotkeyModifiers(binding.chord.modifiers)))
        }
        let failures = hotkeys.replaceAll(with: hotkeyList) { [weak self] id in
            MainActor.assumeIsolated { self?.hotkeyPressed(id) }
        }
        reportHotkeyFailures(failures)
    }

    private func hotkeyPressed(_ id: UInt32) {
        guard let descriptor = hotkeyDescriptors[id] else { return }
        manager.handleHotkey(descriptor)
        flush()
    }

    private func reportHotkeyFailures(_ failures: [HotkeyRegistrationFailure]) {
        guard !failures.isEmpty else { return }
        let lines = failures.map { failure in
            let name = hotkeyDescriptors[failure.hotkey.id] ?? "hotkey \(failure.hotkey.id)"
            return failure.isAlreadyTaken
                ? "\(name): already used by another app or a system shortcut"
                : "\(name): couldn't be registered (OSStatus \(failure.status))"
        }
        NSLog("Silk: hotkey registration problems:\n%@", lines.joined(separator: "\n"))
    }
}

// MARK: - CLI (IPC)

extension Engine {
    func startIPC() {
        let server = IPCServer(
            endpoints: [.silk(), .aerospace],
            initialEvents: { [weak self] types in
                // Called on the handler queue (main)
                MainActor.assumeIsolated {
                    guard let self, self.manager != nil else { return [] }
                    let coreTypes = Set(types.compactMap { SilkCore.ServerEventType(rawValue: $0.rawValue) })
                    return self.manager.initialSubscribeEvents(for: coreTypes).map(SilkIPC.ServerEvent.init)
                }
            },
            onEndpointLost: { endpoint in
                NSLog("Silk: another process took over the socket %@", endpoint.path)
            },
            handler: { [weak self] request, reply in
                MainActor.assumeIsolated { self?.handle(request, reply: reply) }
            }
        )
        do {
            try server.start()
            ipcServer = server
        } catch {
            NSLog("Silk: couldn't start the command server: \(error)")
        }
    }

    private func handle(_ request: ClientRequest, reply: IPCReply) {
        let env = CommandEnv(windowId: request.windowId, workspace: request.workspace)
        let result = manager.run(args: request.args, stdin: request.stdin, env: env)
        flush()
        var stderr = result.stderr
        if !request.hasContextFields, result.exitCode == 0 {
            stderr = [stderr, ClientRequest.missingContextFieldsWarning].filter { !$0.isEmpty }.joined(separator: "\n")
        }
        reply.send(exitCode: result.exitCode, stdout: result.stdout, stderr: stderr)
    }
}

// MARK: - Menu bar

extension Engine: StatusBarActions {
    /// Refreshes the menu bar at the end of the current main-queue turn (many events per turn
    /// cause one refresh).
    func updateStatusBar() {
        guard !statusBarUpdateScheduled else { return }
        statusBarUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.statusBarUpdateScheduled = false
            self.refreshStatusBar()
        }
    }

    private func refreshStatusBar() {
        guard let manager else { return }
        let model = manager.menuBarModel()
        let workspaces = model.workspaces.map {
            MenuBarState.Workspace(name: $0.name, suffix: $0.suffix, isFocused: $0.isFocused, isVisible: $0.isVisible, hasFullscreenWindows: $0.hasFullscreenWindows)
        }
        var state = MenuBarState()
        state.status = AccessibilityPermission.isTrusted ? (model.isEnabled ? .running : .disabled) : .needsAccessibility
        state.text = model.text
        state.mode = model.mode.flatMap { $0 == "main" ? nil : $0 }
        state.visibleWorkspaces = model.visibleWorkspaces.compactMap { name in workspaces.first { $0.name == name } }
        state.workspaces = workspaces
        state.configHasProblems = hasConfigProblems
        state.secureInputActive = platform.isSecureInputEnabled
        state.launchAtLogin = LoginItem.isEnabled
        statusBar.update(state)
    }

    func statusBarFocusWorkspace(_ name: String) {
        _ = manager.run(args: ["workspace", name])
        flush()
    }

    func statusBarToggleEnabled() {
        _ = manager.run(args: ["enable", "toggle"])
        flush()
    }

    func statusBarReloadConfig() {
        let result = manager.run(args: ["reload-config"])
        flush()
        if result.exitCode != 0, !result.stderr.isEmpty { showConfigMessage(result.stderr) }
    }

    func statusBarOpenConfig() {
        let url = configURL ?? createUserConfig()
        guard let url else { return }
        let editor = NSWorkspace.shared.urlForApplication(toOpen: url).flatMap { $0.lastPathComponent == "Xcode.app" ? nil : $0 }
            ?? URL(filePath: "/System/Applications/TextEdit.app")
        NSWorkspace.shared.open([url], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
    }

    func statusBarShowConfigProblems() {
        let messages = configLoad.diagnostics.map(\.description) + manager.configDiagnostics.map(\.description)
        showConfigMessage(messages.joined(separator: "\n"))
    }

    func statusBarRequestAccessibility() {
        _ = AccessibilityPermission.prompt()
    }

    func statusBarToggleLaunchAtLogin() {
        if let error = LoginItem.set(enabled: !LoginItem.isEnabled) {
            showMessage(title: "Launch at Login", heading: error, body: "")
        }
        updateStatusBar()
    }

    func statusBarQuit() {
        NSApp.terminate(nil)
    }

    /// Copies the bundled default config to ~/.silk.toml when the user has no config yet.
    private func createUserConfig() -> URL? {
        let url = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".silk.toml")
        guard let source = Bundle.module(named: "Silk_SilkConfig")?.url(forResource: "default-config", withExtension: "toml") else { return nil }
        try? FileManager.default.copyItem(at: source, to: url)
        configURL = url
        return url
    }
}

// MARK: - Config problems, settings and warnings

extension Engine {
    func reportConfigProblems(_ load: ConfigLoadResult, _ commandDiagnostics: [ConfigDiagnostic]) {
        let errors = load.errors + commandDiagnostics.filter { $0.severity == .error }
        hasConfigProblems = !(load.diagnostics + commandDiagnostics).isEmpty
        guard !errors.isEmpty else { return }
        showConfigMessage((load.diagnostics + commandDiagnostics).map(\.description).joined(separator: "\n"))
    }

    func showConfigMessage(_ message: String) {
        showMessage(
            title: "Silk Config",
            heading: "Silk found problems in \(configURL?.path(percentEncoded: false) ?? "the config")",
            body: message,
            buttons: [
                .init(title: "Open Config") { [weak self] in self?.statusBarOpenConfig() },
                .init(title: "Reload", isDefault: true) { [weak self] in self?.statusBarReloadConfig() },
            ]
        )
    }

    func showMessage(title: String, heading: String, body: String, buttons: [MessageWindow.Button] = []) {
        let close = MessageWindow.Button(title: "Close") { [weak self] in self?.configWindow.close() }
        configWindow.show(title: title, heading: heading, body: body, buttons: [close] + buttons)
    }

    /// Animation and border settings from the config.
    func applyAppearanceSettings(_ config: Config) {
        animator.update(settings: AnimationSettings(config.animations))
        if config.borders.enabled {
            let settings = BorderSettings(config.borders)
            if let border {
                border.update(settings: settings)
            } else {
                setBorder(BorderController(settings: settings))
            }
        } else {
            border?.hide()
            setBorder(nil)
        }
        updateFocusFollowsMouse(config.focusFollowsMouse)
    }

    private func updateFocusFollowsMouse(_ enabled: Bool) {
        if enabled, focusFollowsMouseMonitor == nil {
            focusFollowsMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, !self.platform.isLeftMouseDown else { return }
                    if self.manager.focusFollowsMouse(at: self.platform.mouseLocation) != nil { self.flush() }
                }
            }
        } else if !enabled, let monitor = focusFollowsMouseMonitor {
            NSEvent.removeMonitor(monitor)
            focusFollowsMouseMonitor = nil
        }
    }

    func warnAboutStageManager() {
        guard SystemState.isStageManagerEnabled else { return }
        showMessage(
            title: "Stage Manager",
            heading: "Stage Manager is on",
            body: "Stage Manager moves and scales windows itself, which conflicts with tiling.\n"
                + "Turn it off in System Settings → Desktop & Dock → Stage Manager."
        )
    }
}

private extension Bundle {
    /// A SwiftPM resource bundle next to the app's resources (or the executable for `swift run`).
    static func module(named name: String) -> Bundle? {
        let candidates = [Bundle.main.resourceURL, Bundle.main.bundleURL, Bundle.main.executableURL?.deletingLastPathComponent()]
        return candidates.compactMap { $0?.appending(path: "\(name).bundle") }.lazy.compactMap(Bundle.init(url:)).first
    }
}
