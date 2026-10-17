import Foundation

// The config model. AeroSpace keys keep AeroSpace's names and semantics so an unmodified
// ~/.aerospace.toml loads as-is; Silk-only options live under [animations] and [borders].
//
// Command scripts are stored as raw source strings ("layout tiles horizontal vertical",
// "exec-and-forget open -n /Applications/Ghostty.app"). SilkCore parses and validates them;
// SilkConfig has no knowledge of the command language.

/// One or more command scripts, run in order. A TOML string is one script; a TOML array
/// of strings is several. An empty list means "do nothing".
public struct CommandScripts: Equatable, Sendable {
    public var scripts: [String]
    public init(_ scripts: [String] = []) { self.scripts = scripts }
    public static let empty = CommandScripts()
    public var isEmpty: Bool { scripts.isEmpty }
}

public enum ContainerLayout: String, Equatable, Sendable, CaseIterable {
    case tiles, accordion
}

public enum DefaultOrientation: String, Equatable, Sendable, CaseIterable {
    case horizontal, vertical, auto
}

/// Monitor selector used by per-monitor gaps and workspace-to-monitor-force-assignment.
public enum MonitorPattern: Equatable, Sendable {
    case main
    case secondary
    case builtIn
    /// 1-based, ordered left-to-right then top-to-bottom (AeroSpace's `sequence-number`).
    case sequenceNumber(Int)
    /// Case-insensitive regex matched against the monitor name.
    case nameRegex(String)
}

public struct PerMonitorValue<Value: Equatable & Sendable>: Equatable, Sendable {
    public var monitor: MonitorPattern
    public var value: Value
    public init(monitor: MonitorPattern, value: Value) { self.monitor = monitor; self.value = value }
}

/// A value that is either constant or chosen by the first matching monitor pattern.
public enum DynamicValue<Value: Equatable & Sendable>: Equatable, Sendable {
    case constant(Value)
    case perMonitor([PerMonitorValue<Value>], default: Value)
}

public struct Gaps: Equatable, Sendable {
    public struct Inner: Equatable, Sendable {
        public var horizontal: DynamicValue<Int> = .constant(0)
        public var vertical: DynamicValue<Int> = .constant(0)
        public init() {}
    }
    public struct Outer: Equatable, Sendable {
        public var left: DynamicValue<Int> = .constant(0)
        public var right: DynamicValue<Int> = .constant(0)
        public var top: DynamicValue<Int> = .constant(0)
        public var bottom: DynamicValue<Int> = .constant(0)
        public init() {}
    }
    public var inner = Inner()
    public var outer = Outer()
    public init() {}
}

public enum Modifier: String, Equatable, Hashable, Sendable, CaseIterable {
    case cmd, alt, ctrl, shift
}

/// A parsed hotkey such as `alt-shift-h`.
public struct KeyChord: Equatable, Hashable, Sendable {
    public var modifiers: Set<Modifier>
    /// Key notation as written in the config (after modifiers), e.g. "h", "enter", "keypad1".
    public var key: String
    /// Virtual key code (kVK_*) resolved through the active key mapping.
    public var keyCode: UInt32
    public init(modifiers: Set<Modifier>, key: String, keyCode: UInt32) {
        self.modifiers = modifiers; self.key = key; self.keyCode = keyCode
    }
}

public struct Binding: Equatable, Sendable {
    /// The binding as written in the config, e.g. "alt-shift-h". Used by `trigger-binding`.
    public var descriptor: String
    public var chord: KeyChord
    public var commands: CommandScripts
    public init(descriptor: String, chord: KeyChord, commands: CommandScripts) {
        self.descriptor = descriptor; self.chord = chord; self.commands = commands
    }
}

public struct Mode: Equatable, Sendable {
    public var name: String
    /// Keyed by `Binding.descriptor`, insertion order irrelevant.
    public var bindings: [String: Binding]
    public init(name: String, bindings: [String: Binding] = [:]) { self.name = name; self.bindings = bindings }
}

public enum KeyMappingPreset: String, Equatable, Sendable, CaseIterable {
    case qwerty, dvorak, colemak
}

public struct KeyMapping: Equatable, Sendable {
    public var preset: KeyMappingPreset = .qwerty
    /// `[key-mapping.key-notation-to-key-code]` overrides: notation → key code.
    public var overrides: [String: UInt32] = [:]
    public init() {}
}

public struct WindowDetectedMatcher: Equatable, Sendable {
    public var appId: String?
    /// Case-insensitive regex, substring match.
    public var appNameRegexSubstring: String?
    /// Case-insensitive regex, substring match.
    public var windowTitleRegexSubstring: String?
    public var workspace: String?
    public var duringStartup: Bool?
    public init() {}
}

public struct WindowDetectedRule: Equatable, Sendable {
    public var matcher = WindowDetectedMatcher()
    public var checkFurtherCallbacks = false
    public var run = CommandScripts.empty
    public init() {}
}

public struct ExecConfig: Equatable, Sendable {
    public var inheritEnvVars = true
    /// Values may reference other variables as `${VAR}`; expansion happens at exec time.
    public var env: [String: String] = [:]
    public init() {}
}

// MARK: Silk extensions

public enum AnimationCurve: Equatable, Sendable {
    /// Cubic bezier control points (x1, y1, x2, y2), as in Hyprland's `bezier =` and CSS.
    case bezier(Double, Double, Double, Double)
    /// Damped spring. `damping` 1.0 = critically damped; `response` is the period in seconds.
    case spring(response: Double, damping: Double)
    case linear

    /// Hyprland's default curve (`bezier = myBezier, 0.05, 0.9, 0.1, 1.05`).
    public static let hyprland = AnimationCurve.bezier(0.05, 0.9, 0.1, 1.05)
    public static let easeOut = AnimationCurve.bezier(0.16, 1, 0.3, 1)
}

public enum WindowOpenAnimation: String, Equatable, Sendable, CaseIterable {
    case popin, none
}

public enum WorkspaceSwitchAnimation: String, Equatable, Sendable, CaseIterable {
    case slide, none
}

public struct AnimationConfig: Equatable, Sendable {
    public var enabled = true
    /// Milliseconds for window move/resize animations.
    public var duration = 180
    public var curve: AnimationCurve = .hyprland
    public var windowOpen: WindowOpenAnimation = .popin
    public var workspaceSwitch: WorkspaceSwitchAnimation = .slide
    /// Milliseconds for workspace switch animations.
    public var workspaceDuration = 220
    public init() {}
}

public struct RGBAColor: Equatable, Sendable {
    public var red: Double, green: Double, blue: Double, alpha: Double
    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
    }
}

public struct BorderConfig: Equatable, Sendable {
    public var enabled = true
    public var width = 2.0
    public var activeColor = RGBAColor(red: 0x89 / 255, green: 0xB4 / 255, blue: 0xFA / 255)
    /// Corner radius in points. macOS 26 standard windows use ~16pt.
    public var radius = 16.0
    public init() {}
}

// MARK: Root

public struct Config: Equatable, Sendable {
    public var configVersion = 1
    public var afterStartupCommand = CommandScripts.empty
    public var startAtLogin = false
    public var autoReloadConfig = false
    public var automaticallyUnhideMacosHiddenApps = false
    public var enableNormalizationFlattenContainers = true
    public var enableNormalizationOppositeOrientationForNestedContainers = true
    public var accordionPadding = 30
    public var defaultRootContainerLayout: ContainerLayout = .tiles
    public var defaultRootContainerOrientation: DefaultOrientation = .auto
    /// Ordered, unique.
    public var persistentWorkspaces: [String] = []
    public var execOnWorkspaceChange: [String] = []
    public var onFocusChanged = CommandScripts.empty
    public var onFocusedMonitorChanged = CommandScripts.empty
    public var onModeChanged = CommandScripts.empty
    public var focusFollowsMouse = false
    public var keyMapping = KeyMapping()
    public var exec = ExecConfig()
    public var gaps = Gaps()
    /// Workspace name → candidate monitors, first available wins.
    public var workspaceToMonitorForceAssignment: [String: [MonitorPattern]] = [:]
    /// Always contains "main".
    public var modes: [String: Mode] = ["main": Mode(name: "main")]
    public var onWindowDetected: [WindowDetectedRule] = []

    public var animations = AnimationConfig()
    public var borders = BorderConfig()

    public init() {}
}

// MARK: Loading results

public struct ConfigDiagnostic: Equatable, Sendable, CustomStringConvertible {
    public enum Severity: String, Sendable { case error = "ERROR", warning = "WARNING" }
    public var severity: Severity
    /// Dotted key path, e.g. "mode.main.binding.alt-h" or "gaps.outer.top[1]". Empty for file-level problems.
    public var keyPath: String
    public var message: String
    public init(_ severity: Severity, _ keyPath: String, _ message: String) {
        self.severity = severity; self.keyPath = keyPath; self.message = message
    }
    public var description: String {
        keyPath.isEmpty ? "[\(severity.rawValue)] \(message)" : "[\(severity.rawValue)] \(keyPath): \(message)"
    }
}

public struct ConfigLoadResult: Equatable, Sendable {
    public var config: Config
    /// Nil when no config file exists and built-in defaults were used.
    public var url: URL?
    public var diagnostics: [ConfigDiagnostic]
    /// A fatal error (unreadable file, TOML syntax error, ambiguous configs): `config` is the default
    /// config and callers that already have a working config should keep it instead.
    public var isFatal: Bool
    public init(config: Config, url: URL?, diagnostics: [ConfigDiagnostic], isFatal: Bool) {
        self.config = config; self.url = url; self.diagnostics = diagnostics; self.isFatal = isFatal
    }
    public var errors: [ConfigDiagnostic] { diagnostics.filter { $0.severity == .error } }
}
