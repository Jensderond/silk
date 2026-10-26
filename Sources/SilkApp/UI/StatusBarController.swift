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
    /// AeroSpace's tray text, e.g. `(S) *1 │ 10`: the default (monospaced text) label.
    var text = ""
    /// Non-main binding mode, shown as a badge before the workspaces.
    var mode: String?
    /// Visible workspace per monitor, ordered like the monitors (left to right).
    var visibleWorkspaces: [Workspace] = []
    var workspaces: [Workspace] = []
    var configHasProblems = false
    var secureInputActive = false
    /// A newer GitHub release than the running build.
    var update: UpdateChecker.Release?
    /// `update` is downloaded and verified: the menu offers to restart into it.
    var updateIsReady = false
}

/// Actions the menu can trigger. Implemented by the engine.
@MainActor
protocol StatusBarActions: AnyObject {
    func statusBarFocusWorkspace(_ name: String)
    func statusBarToggleEnabled()
    func statusBarReloadConfig()
    func statusBarOpenConfig()
    func statusBarShowConfigProblems()
    func statusBarRequestAccessibility()
    func statusBarOpenUpdate()
    func statusBarInstallUpdate()
    func statusBarCheckForUpdates()
    func statusBarQuit()
}

@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    /// AeroSpace's label styles; text is AeroSpace's default.
    enum Style: String, CaseIterable {
        case text, squares
        var title: String { self == .text ? "Monospaced Text" : "Squares" }
    }

    private static let styleKey = "menuBarStyle"
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private weak var actions: StatusBarActions?
    private var state = MenuBarState()
    private var style = Style(rawValue: UserDefaults.standard.string(forKey: StatusBarController.styleKey) ?? "") ?? .text
    /// Update badge on the label's top-right corner. A separate view because the label is a
    /// template image, which the menu bar recolors: a dot drawn into it couldn't stay green.
    private let updateDot = UpdateDot(frame: NSRect(x: 0, y: 0, width: UpdateDot.size, height: UpdateDot.size))

    init(actions: StatusBarActions) {
        self.actions = actions
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        item.button?.addSubview(updateDot)
        render()
    }

    func update(_ newState: MenuBarState) {
        guard newState != state else { return }
        let labelChanged = newState.status != state.status || newState.mode != state.mode || newState.text != state.text
            || newState.visibleWorkspaces != state.visibleWorkspaces || newState.secureInputActive != state.secureInputActive
            || newState.update != state.update
        state = newState
        if labelChanged { render() }
    }

    // MARK: Label

    private func render() {
        guard let button = item.button else { return }
        let contentWidth: CGFloat
        if style == .text, state.status == .running, !state.text.isEmpty {
            button.image = state.secureInputActive ? StatusBarLabel.lockImage : nil
            button.imagePosition = .imageLeading
            let title = NSMutableAttributedString(
                string: state.text,
                attributes: [.font: NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)]
            )
            if state.update != nil {
                // Room for the dot after the last character
                title.addAttribute(.kern, value: UpdateDot.reservedWidth, range: NSRange(location: title.length - 1, length: 1))
            }
            button.attributedTitle = title
            contentWidth = title.size().width + (button.image.map { $0.size.width + 2 } ?? 0)
        } else {
            button.title = ""
            button.image = StatusBarLabel.image(for: state)
            button.imagePosition = .imageOnly
            contentWidth = button.image?.size.width ?? 0
        }
        button.toolTip = tooltip
        button.setAccessibilityLabel(tooltip)
        placeUpdateDot(in: button, contentWidth: contentWidth)
    }

    /// Puts the dot in the room reserved at the end of the label, level with the top of the glyphs.
    /// The label is centered in the button, so the dot keeps its place relative to the center
    /// (flexible margins on all sides) when the menu bar resizes the button.
    private func placeUpdateDot(in button: NSStatusBarButton, contentWidth: CGFloat) {
        updateDot.isHidden = state.update == nil
        guard state.update != nil else { return }
        let bounds = button.bounds
        let centerY = button.isFlipped ? bounds.midY - UpdateDot.raise : bounds.midY + UpdateDot.raise
        updateDot.frame = NSRect(
            x: (bounds.midX + contentWidth / 2 - UpdateDot.size).rounded(),
            y: (centerY - UpdateDot.size / 2).rounded(),
            width: UpdateDot.size,
            height: UpdateDot.size
        )
        updateDot.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
    }

    private var tooltip: String {
        let base = statusTooltip
        return state.update.map { "\(base) — Silk \($0.version) is available" } ?? base
    }

    private var statusTooltip: String {
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
        if let update = state.update {
            let entry = state.updateIsReady
                ? actionItem("Restart to Update to Silk \(update.version)", #selector(installUpdate))
                : actionItem("Silk \(update.version) Is Available…", #selector(openUpdate))
            entry.image = NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: nil)
            menu.addItem(entry)
        }
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
                let styles = NSMenu()
                for option in Style.allCases {
                    let entry = actionItem(option.title, #selector(selectStyle(_:)))
                    entry.representedObject = option.rawValue
                    entry.state = option == style ? .on : .off
                    styles.addItem(entry)
                }
                let styleItem = NSMenuItem(title: "Menu Bar Style", action: nil, keyEquivalent: "")
                styleItem.submenu = styles
                menu.addItem(styleItem)
        }
        menu.addItem(.separator())
        menu.addItem(actionItem("Check for Updates…", #selector(checkForUpdates)))
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
    @objc private func openUpdate() { actions?.statusBarOpenUpdate() }
    @objc private func installUpdate() { actions?.statusBarInstallUpdate() }
    @objc private func checkForUpdates() { actions?.statusBarCheckForUpdates() }
    @objc private func quit() { actions?.statusBarQuit() }
    @objc private func selectStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let selected = Style(rawValue: raw) else { return }
        style = selected
        UserDefaults.standard.set(raw, forKey: Self.styleKey)
        render()
    }
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
        if let initial = state.mode?.first { parts.append(glyph(for: String(initial).uppercased(), style: .mode)) }
        for workspace in state.visibleWorkspaces {
            let style: GlyphStyle = workspace.isFocused || state.visibleWorkspaces.count == 1 ? .focused : .visible
            parts.append(glyph(for: workspace.name, style: style, fullscreen: workspace.hasFullscreenWindows))
        }
        if parts.isEmpty { parts.append(symbol("square.grid.2x2")) }
        if state.update != nil {
            // Room for the update dot, which the status bar controller draws on top
            parts.append(NSImage(size: NSSize(width: max(UpdateDot.reservedWidth - spacing, 0), height: height)))
        }
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

    static var lockImage: NSImage { symbol("lock.fill") }

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

/// The green "update available" dot. Draws with the current appearance, so it suits light and dark menu bars.
final class UpdateDot: NSView {
    static let size: CGFloat = 6
    /// Space the label leaves free for the dot after its last glyph.
    static let reservedWidth: CGFloat = size + 3
    /// How far the dot's center sits above the label's center: level with the top of the glyphs.
    static let raise: CGFloat = 5

    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemGreen.setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }

    /// Clicks go to the status item button underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
