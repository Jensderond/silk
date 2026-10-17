import Foundation

/// A formatted value (`test` compares by its type).
enum Primitive: Encodable, Equatable {
    case bool(Bool)
    case int(Int64)
    case string(String)

    enum Kind: String {
        case bool = "Bool"
        case int = "Int"
        case string = "String"
    }

    var kind: Kind {
        switch self {
            case .bool: .bool
            case .int: .int
            case .string: .string
        }
    }

    var stringValue: String {
        switch self {
            case .bool(let value): value.description
            case .int(let value): value.description
            case .string(let value): value
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
            case .bool(let value): try container.encode(value)
            case .int(let value): try container.encode(value)
            case .string(let value): try container.encode(value)
        }
    }
}

/// An object a format string is expanded against.
enum AeroObj {
    /// `title` is only fetched when the format needs it (AeroSpace `WindowWithPrefetchedTitle`).
    case window(Window, title: String?)
    case workspace(Workspace)
    case app(AppInfo)
    case monitor(Monitor)

    var kind: AeroObjKind {
        switch self {
            case .window: .window
            case .workspace: .workspace
            case .app: .app
            case .monitor: .monitor
        }
    }
}

/// All expansion errors of a format call.
struct FormatErrors: Error {
    let errors: [InterVarExpansionError]
}

enum InterVarExpansionError: Error, CustomStringConvertible {
    case unknownInterpolationVariable(String)
    case nullParent(String)
    case notPossible(String)
    case rightPaddingCannotBeExpanded(String)

    var description: String {
        switch self {
            case .unknownInterpolationVariable(let message), .nullParent(let message), .notPossible(let message),
                 .rightPaddingCannotBeExpanded(let message):
                message
        }
    }
}

/// Expands format variables against the world. Looks running apps up lazily, once.
final class Formatter {
    private let world: World
    private lazy var appsByPid: [pid_t: AppInfo] = Dictionary(
        world.platform.runningApps().map { ($0.pid, $0) },
        uniquingKeysWith: { first, _ in first }
    )

    init(world: World) { self.world = world }

    func app(of window: Window) -> AppInfo {
        let running = appsByPid[window.pid]
        return AppInfo(
            pid: window.pid,
            bundleId: window.bundleId ?? running?.bundleId,
            name: window.appName ?? running?.name,
            execPath: running?.execPath,
            bundlePath: running?.bundlePath,
            isHidden: running?.isHidden ?? false
        )
    }

    func expand(_ variable: FormatVar, _ object: AeroObj) -> Result<Primitive, InterVarExpansionError> {
        switch (object, variable) {
            case (.window(let window, _), .workspace):
                guard let workspace = window.nodeWorkspace else { return .success(.string("NULL-WORKSPACE")) }
                return expand(variable, .workspace(workspace))
            case (.window(let window, _), .monitor):
                guard let workspace = window.nodeWorkspace else { return .success(.string("NULL-MONITOR")) }
                return expand(variable, .monitor(world.monitor(of: workspace)))
            case (.window(let window, _), .app):
                return expand(variable, .app(app(of: window)))
            case (.workspace(let workspace), .monitor):
                return expand(variable, .monitor(world.monitor(of: workspace)))

            case (.window(let window, let title), .window(let windowVar)):
                switch windowVar {
                    case .windowId: return .success(.int(Int64(window.id)))
                    case .windowIsFullscreen: return .success(.bool(window.isFullscreen))
                    case .windowTitle: return .success(.string(title ?? window.title))
                    case .windowLayout, .windowParentContainerLayout: return layoutDescription(of: window)
                }
            case (.workspace(let workspace), .workspace(let workspaceVar)):
                return switch workspaceVar {
                    case .workspaceName: .success(.string(workspace.name))
                    case .workspaceVisible: .success(.bool(world.isVisible(workspace)))
                    case .workspaceFocused: .success(.bool(world.focus.workspace === workspace))
                    case .workspaceRootContainerLayout: .success(.string(layoutString(workspace.rootTilingContainer)))
                }
            case (.monitor(let monitor), .monitor(let monitorVar)):
                return switch monitorVar {
                    case .monitorId: .success(world.monitorId1Based(monitor).map { .int(Int64($0)) } ?? .string("NULL-MONITOR-ID"))
                    case .monitorAppKitNsScreenScreensId: .success(.int(Int64(world.appKitScreenIndex(monitor))))
                    case .monitorName: .success(.string(monitor.name))
                    case .monitorIsMain: .success(.bool(monitor.isMain))
                }
            case (.app(let app), .app(let appVar)):
                return switch appVar {
                    case .appBundleId: .success(.string(app.bundleId ?? "NULL-APP-BUNDLE-ID"))
                    case .appName: .success(.string(app.name ?? "NULL-APP-NAME"))
                    case .appPid: .success(.int(Int64(app.pid)))
                    case .appExecPath: .success(.string(app.execPath ?? "NULL-APP-EXEC-PATH"))
                    case .appBundlePath: .success(.string(app.bundlePath ?? "NULL-APP-BUNDLE-PATH"))
                }
            default:
                let values = availableInterVars(for: object.kind).joined(separator: "\n").prependingLines("  ")
                return .failure(.unknownInterpolationVariable("Unknown interpolation variable '\(variable.rawValue)'. Possible values:\n\(values)"))
        }
    }

    func expand(_ variable: InterVar, _ object: AeroObj) -> Result<Primitive, InterVarExpansionError> {
        switch variable {
            case .formatVar(let formatVar): expand(formatVar, object)
            case .plain(.newline): .success(.string("\n"))
            case .plain(.tab): .success(.string("\t"))
            case .plain(.rightPadding): .failure(.rightPaddingCannotBeExpanded("'right-padding' interpolation variable cannot be expanded"))
        }
    }

    /// One line per object; `%{right-padding}` pads its column to the widest cell.
    func format(_ objects: [AeroObj], _ tokens: FormatTokens) -> Result<[String], FormatErrors> {
        struct Cell {
            let value: String
            let rightPadding: Bool
        }
        var table: [[Cell]] = []
        for object in objects {
            var line: [Cell] = []
            var current = ""
            var errors: [InterVarExpansionError] = []
            for token in tokens {
                switch token {
                    case .interVar(.plain(.rightPadding)):
                        line.append(Cell(value: current, rightPadding: true))
                        current = ""
                    case .literal(let literal):
                        current += literal
                    case .interVar(let variable):
                        switch expand(variable, object) {
                            case .success(let value): current += value.stringValue
                            case .failure(let error): errors.append(error)
                        }
                }
            }
            if !errors.isEmpty { return .failure(FormatErrors(errors: errors)) }
            line.append(Cell(value: current, rightPadding: false))
            table.append(line)
        }
        guard let columnCount = table.first?.count else { return .success([]) }
        let widths = (0 ..< columnCount).map { column in table.map { $0[column].value.count }.max() ?? 0 }
        return .success(table.map { line in
            line.enumerated().map { column, cell in
                cell.rightPadding ? cell.value + String(repeating: " ", count: widths[column] - cell.value.count) : cell.value
            }.joined()
        })
    }

    /// `--json`: an array of objects keyed by variable name.
    func formatJSON(_ objects: [AeroObj], _ tokens: FormatTokens, ignoreRightPadding: Bool) -> Result<String, ParseError> {
        var list: [[String: Primitive]] = []
        for object in objects {
            var entry: [String: Primitive] = [:]
            for token in tokens {
                switch token {
                    case .interVar(.plain(.rightPadding)) where ignoreRightPadding:
                        break
                    case .literal:
                        break // Only spaces are allowed
                    case .interVar(let variable):
                        switch expand(variable, object) {
                            case .success(let value): entry[variable.rawValue] = value
                            case .failure(let error): return .failure(ParseError(error.description))
                        }
                }
            }
            list.append(entry)
        }
        return JSONEncoder.aeroSpace.encodeToString(list).map { .success($0) } ?? .failure(ParseError("Can't encode '\(list)' to JSON"))
    }

    private func layoutDescription(of window: Window) -> Result<Primitive, InterVarExpansionError> {
        switch window.parent {
            case nil: .failure(.nullParent("NULL-PARENT"))
            case let container as TilingContainer: .success(.string(layoutString(container)))
            case is FloatingWindowsContainer: .success(.string(LayoutCommand.LayoutDescription.floating.rawValue))
            case is MacosFullscreenWindowsContainer: .success(.string("macos_native_fullscreen"))
            case is MacosHiddenAppsWindowsContainer: .success(.string("macos_native_window_of_hidden_app"))
            case is MacosMinimizedWindowsContainer: .success(.string("macos_native_minimized"))
            case is MacosPopupWindowsContainer: .success(.string("NULL-WINDOW-LAYOUT"))
            default: .failure(.notPossible("Not possible"))
        }
    }
}

/// `h_tiles`, `v_accordion`, …
func layoutString(_ container: TilingContainer) -> String {
    let description: LayoutCommand.LayoutDescription = switch (container.layout, container.orientation) {
        case (.tiles, .h): .h_tiles
        case (.tiles, .v): .v_tiles
        case (.accordion, .h): .h_accordion
        case (.accordion, .v): .v_accordion
    }
    return description.rawValue
}

extension JSONEncoder {
    /// AeroSpace's JSON output settings.
    static var aeroSpace: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
        return encoder
    }

    func encodeToString(_ value: some Encodable) -> String? {
        guard let data = try? encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
