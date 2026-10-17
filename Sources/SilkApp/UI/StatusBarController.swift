import AppKit

/// Everything the menu bar shows. Built by the engine; rendering is a pure function of it.
struct MenuBarState: Equatable {
    struct Workspace: Equatable {
        var name: String
        /// " - Ghostty, Slack" or " - LG ULTRAFINE", like AeroSpace's tray menu.
        var suffix: String
        var isFocused: Bool
        var isVisible: Bool
        var hasFullscreenWindows: Bool
    }

    enum Status: Equatable {
        case running
        case disabled
        case needsAccessibility
    }

    var status: Status = .needsAccessibility
    /// Non-main binding mode, shown as a badge before the workspaces.
    var mode: String?
    /// Visible workspace per monitor, ordered like the monitors (left to right).
    var visibleWorkspaces: [Workspace] = []
    var workspaces: [Workspace] = []
    var configHasProblems = false
    var secureInputActive = false
    var launchAtLogin = false
}

/// Actions the menu can trigger. Implemented by the engine.
protocol StatusBarActions: AnyObject {
    func statusBarFocusWorkspace(_ name: String)
    func statusBarToggleEnabled()
    func statusBarReloadConfig()
    func statusBarOpenConfig()
    func statusBarShowConfigProblems()
    func statusBarRequestAccessibility()
    func statusBarToggleLaunchAtLogin()
    func statusBarQuit()
}

final class StatusBarController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private weak var actions: StatusBarActions?
    private var state = MenuBarState()

    init(actions: StatusBarActions) {
        self.actions = actions
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        render()
    }

    func update(_ newState: MenuBarState) {
        guard newState != state else { return }
        let labelChanged = newState.status != state.status || newState.mode != state.mode
            || newState.visibleWorkspaces != state.visibleWorkspaces || newState.secureInputActive != state.secureInputActive
        state = newState
        if labelChanged { render() }
    }

    // MARK: Label

    private func render() {
        guard let button = item.button else { return }
        button.image = StatusBarLabel.image(for: state)
        button.imagePosition = .imageOnly
        button.toolTip = tooltip
        button.setAccessibilityLabel(tooltip)
    }

    private var tooltip: String {
        switch state.status {
            case .needsAccessibility: return "Silk needs Accessibility permission"
            case .disabled: return "Silk is disabled"
            case .running:
                let names = state.visibleWorkspaces.map(\.name).joined(separator: ", ")
                return state.mode.map { "Silk — mode \($0) — \(names)" } ?? "Silk — \(names)"
        }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        menu.addItem(disabledItem("Silk \(version)"))
        menu.addItem(.separator())

        switch state.status {
            case .needsAccessibility:
                menu.addItem(actionItem("Grant Accessibility Permission…", #selector(requestAccessibility)))
            case .running, .disabled:
                if state.configHasProblems {
                    let problems = actionItem("Config contains problems…", #selector(showConfigProblems))
                    problems.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
                    menu.addItem(problems)
                    menu.addItem(.separator())
                }
                if state.secureInputActive {
                    let secure = disabledItem("Secure input is on — hotkeys are paused")
                    secure.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil)
                    menu.addItem(secure)
                    menu.addItem(.separator())
                }
                if state.status == .running {
                    menu.addItem(disabledItem("Workspaces:"))
                    for workspace in state.workspaces {
                        let entry = actionItem(workspace.name + workspace.suffix, #selector(focusWorkspace(_:)))
                        entry.representedObject = workspace.name
                        entry.state = workspace.isFocused ? .on : .off
                        entry.attributedTitle = NSAttributedString(
                            string: entry.title,
                            attributes: [.font: NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)]
                        )
                        menu.addItem(entry)
                    }
                    menu.addItem(.separator())
                }
                menu.addItem(actionItem(state.status == .running ? "Disable" : "Enable", #selector(toggleEnabled), key: "e"))
                menu.addItem(actionItem("Open Config", #selector(openConfig), key: ","))
                menu.addItem(actionItem("Reload Config", #selector(reloadConfig), key: "r"))
                let login = actionItem("Launch at Login", #selector(toggleLaunchAtLogin))
                login.state = state.launchAtLogin ? .on : .off
                menu.addItem(login)
        }
        menu.addItem(.separator())
        menu.addItem(actionItem("Quit Silk", #selector(quit), key: "q"))
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func actionItem(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func focusWorkspace(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        actions?.statusBarFocusWorkspace(name)
    }
    @objc private func toggleEnabled() { actions?.statusBarToggleEnabled() }
    @objc private func openConfig() { actions?.statusBarOpenConfig() }
    @objc private func reloadConfig() { actions?.statusBarReloadConfig() }
    @objc private func showConfigProblems() { actions?.statusBarShowConfigProblems() }
    @objc private func requestAccessibility() { actions?.statusBarRequestAccessibility() }
    @objc private func toggleLaunchAtLogin() { actions?.statusBarToggleLaunchAtLogin() }
    @objc private func quit() { actions?.statusBarQuit() }
}

/// Draws the menu bar label: one SF Symbol per visible workspace (`1.square.fill` for the
/// focused one, like AeroSpace), falling back to text for names without a symbol.
enum StatusBarLabel {
    private static let height: CGFloat = 16
    private static let spacing: CGFloat = 4

    static func image(for state: MenuBarState) -> NSImage {
        switch state.status {
            case .needsAccessibility: return symbol("exclamationmark.triangle.fill")
            case .disabled: return symbol("pause.circle.fill")
            case .running: break
        }
        var parts: [NSImage] = []
        if state.secureInputActive { parts.append(symbol("lock.fill")) }
        if let mode = state.mode { parts.append(glyph(for: mode, style: .mode)) }
        for workspace in state.visibleWorkspaces {
            let style: GlyphStyle = workspace.isFocused || state.visibleWorkspaces.count == 1 ? .focused : .visible
            parts.append(glyph(for: workspace.name, style: style, fullscreen: workspace.hasFullscreenWindows))
        }
        if parts.isEmpty { parts.append(symbol("square.grid.2x2")) }
        return compose(parts)
    }

    private enum GlyphStyle { case focused, visible, mode }

    private static func glyph(for name: String, style: GlyphStyle, fullscreen: Bool = false) -> NSImage {
        if let symbolName = symbolName(for: name, style: style, fullscreen: fullscreen), let image = symbolImage(symbolName) {
            return image
        }
        let text = style == .mode ? "(\(name.uppercased()))" : fullscreen ? "[\(name)]" : name
        let weight: NSFont.Weight = style == .focused ? .bold : .regular
        return textImage(text, weight: weight)
    }

    /// SF Symbols exist for 0–50 and single letters A–Z.
    private static func symbolName(for name: String, style: GlyphStyle, fullscreen: Bool) -> String? {
        let lower = name.lowercased()
        if let number = Int(name) {
            guard (0 ... 50).contains(number), String(number) == name else { return nil }
        } else {
            guard name.count == 1, let scalar = name.unicodeScalars.first, ("A" ... "Z").contains(name.uppercased()),
                  scalar.isASCII else { return nil }
        }
        let shape = fullscreen ? "rectangle" : "square"
        switch style {
            case .mode: return "\(lower).circle"
            case .focused: return "\(lower).\(shape).fill"
            case .visible: return "\(lower).\(shape)"
        }
    }

    private static func symbol(_ name: String) -> NSImage {
        let image = symbolImage(name) ?? NSImage(size: NSSize(width: height, height: height))
        image.isTemplate = true
        return image
    }

    private static func symbolImage(_ name: String) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
    }

    private static func textImage(_ text: String, weight: NSFont.Weight) -> NSImage {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: weight),
            .foregroundColor: NSColor.black,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let size = string.size()
        return NSImage(size: NSSize(width: ceil(size.width), height: height), flipped: false) { rect in
            string.draw(at: NSPoint(x: 0, y: (rect.height - size.height) / 2))
            return true
        }
    }

    private static func compose(_ parts: [NSImage]) -> NSImage {
        let width = parts.map(\.size.width).reduce(0, +) + spacing * CGFloat(max(parts.count - 1, 0))
        let image = NSImage(size: NSSize(width: ceil(width), height: height), flipped: false) { _ in
            var x: CGFloat = 0
            for part in parts {
                let y = (height - part.size.height) / 2
                part.draw(in: NSRect(x: x, y: y, width: part.size.width, height: part.size.height))
                x += part.size.width + spacing
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
