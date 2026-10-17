/// Object kinds that `list-*`, `echo` and `test` format.
enum AeroObjKind: CaseIterable {
    case window, workspace, app, monitor
}

/// A `%{…}` variable that expands from an object.
enum FormatVar: Equatable, CaseIterable, RawRepresentable {
    case window(WindowVar)
    case workspace(WorkspaceVar)
    case app(AppVar)
    case monitor(MonitorVar)

    enum WindowVar: String, CaseIterable {
        case windowId = "window-id"
        case windowIsFullscreen = "window-is-fullscreen"
        case windowTitle = "window-title"
        /// Alias of `windowParentContainerLayout`.
        case windowLayout = "window-layout"
        case windowParentContainerLayout = "window-parent-container-layout"
    }

    enum WorkspaceVar: String, CaseIterable {
        case workspaceName = "workspace"
        case workspaceFocused = "workspace-is-focused"
        case workspaceVisible = "workspace-is-visible"
        case workspaceRootContainerLayout = "workspace-root-container-layout"
    }

    enum AppVar: String, CaseIterable {
        case appBundleId = "app-bundle-id"
        case appName = "app-name"
        case appPid = "app-pid"
        case appExecPath = "app-exec-path"
        case appBundlePath = "app-bundle-path"
    }

    enum MonitorVar: String, CaseIterable {
        case monitorId = "monitor-id"
        case monitorAppKitNsScreenScreensId = "monitor-appkit-nsscreen-screens-id"
        case monitorName = "monitor-name"
        case monitorIsMain = "monitor-is-main"
    }

    static var allCases: [FormatVar] {
        WindowVar.allCases.map(FormatVar.window) + WorkspaceVar.allCases.map(FormatVar.workspace)
            + AppVar.allCases.map(FormatVar.app) + MonitorVar.allCases.map(FormatVar.monitor)
    }

    init?(rawValue: String) {
        if let value = WindowVar(rawValue: rawValue) {
            self = .window(value)
        } else if let value = WorkspaceVar(rawValue: rawValue) {
            self = .workspace(value)
        } else if let value = AppVar(rawValue: rawValue) {
            self = .app(value)
        } else if let value = MonitorVar(rawValue: rawValue) {
            self = .monitor(value)
        } else {
            return nil
        }
    }

    var rawValue: String {
        switch self {
            case .window(let value): value.rawValue
            case .workspace(let value): value.rawValue
            case .app(let value): value.rawValue
            case .monitor(let value): value.rawValue
        }
    }
}

/// Variables that don't come from an object.
enum PlainInterVar: String, CaseIterable {
    case rightPadding = "right-padding"
    case newline
    case tab
}

/// Any `%{…}` variable.
enum InterVar: Equatable, CaseIterable, RawRepresentable {
    case formatVar(FormatVar)
    case plain(PlainInterVar)

    static var allCases: [InterVar] { FormatVar.allCases.map(InterVar.formatVar) + PlainInterVar.allCases.map(InterVar.plain) }

    init?(rawValue: String) {
        if let value = FormatVar(rawValue: rawValue) {
            self = .formatVar(value)
        } else if let value = PlainInterVar(rawValue: rawValue) {
            self = .plain(value)
        } else {
            return nil
        }
    }

    var rawValue: String {
        switch self {
            case .formatVar(let value): value.rawValue
            case .plain(let value): value.rawValue
        }
    }
}

/// Variable names valid for `kind` (a window also has its workspace's, app's and monitor's variables).
func availableInterVars(for kind: AeroObjKind) -> [String] {
    func objectVars(_ kind: AeroObjKind) -> [String] {
        switch kind {
            case .app: FormatVar.AppVar.cliArgsCases
            case .monitor: FormatVar.MonitorVar.cliArgsCases
            case .workspace: FormatVar.WorkspaceVar.cliArgsCases + objectVars(.monitor)
            case .window: FormatVar.WindowVar.cliArgsCases + objectVars(.workspace) + objectVars(.app)
        }
    }
    return objectVars(kind) + PlainInterVar.cliArgsCases
}

typealias FormatTokens = [InterToken<InterVar>]

extension FormatTokens {
    var needsWindowTitle: Bool { contains(.interVar(.formatVar(.window(.windowTitle)))) }

    /// AeroSpace's `--json` restrictions on `--format`.
    var jsonIncompatibilityError: String? {
        for token in self {
            switch token {
                case .interVar(.plain(.rightPadding)):
                    return "%{right-padding} interpolation variable is not allowed when --json is used"
                case .interVar:
                    continue
                case .literal(let literal):
                    if literal.contains(where: { $0 != " " }) {
                        return "Only interpolation variables and spaces are allowed in '--format' when '--json' is used"
                    }
            }
        }
        return nil
    }
}

extension FlagParser {
    /// `--format <output-format>`
    static func format(_ keyPath: WritableKeyPath<Root, FormatTokens>, for kind: AeroObjKind) -> FlagParser {
        .value(keyPath) { input in
            guard let arg = input.nonFlagArgOrNil else {
                let values = availableInterVars(for: kind).joined(separator: "\n").prependingLines("  ")
                return .failure("<output-format> is mandatory. Possible values:\n\(values)", advanceBy: 0)
            }
            switch arg.interpolationTokens(interpolationChar: "%", of: InterVar.self) {
                case .success(let tokens): return .success(tokens, advanceBy: 1)
                case .failure(let error): return .failure("Failed to parse <output-format>. \(error)", advanceBy: 1)
            }
        }
    }
}
