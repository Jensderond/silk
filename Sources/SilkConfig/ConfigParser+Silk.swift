import Foundation

// Silk-only options: focus-backend, [animations] and [borders]. AeroSpace rejects these keys, so a config shared with
// AeroSpace should keep them in ~/.silk.toml.

extension ConfigParser {
    static let durationRange = 0 ... 2000
    static let borderWidthRange = 0.0 ... 20.0
    static let borderRadiusRange = 0.0 ... 64.0
    static let springParameterRange = 0.01 ... 5.0

    mutating func parseAnimations(_ value: TOMLValue, _ path: ConfigKeyPath) -> AnimationConfig {
        var animations = AnimationConfig()
        guard let entries = table(value, path) else { return animations }
        for (key, value) in entries {
            let path = path + key
            switch key {
                case "enabled": assign(&animations.enabled, bool(value, path))
                case "duration": assign(&animations.duration, durationMilliseconds(value, path))
                case "curve": assign(&animations.curve, parseCurve(value, path))
                case "window-open": assign(&animations.windowOpen, enumValue(value, path, WindowOpenAnimation.self))
                case "workspace-switch": assign(&animations.workspaceSwitch, enumValue(value, path, WorkspaceSwitchAnimation.self))
                case "workspace-duration": assign(&animations.workspaceDuration, durationMilliseconds(value, path))
                case "respect-reduce-motion": assign(&animations.respectReduceMotion, bool(value, path))
                default: unknownKey(path)
            }
        }
        return animations
    }

    /// Milliseconds; 0 disables the animation.
    private mutating func durationMilliseconds(_ value: TOMLValue, _ path: ConfigKeyPath) -> Int? {
        guard let duration = int(value, path) else { return nil }
        guard Self.durationRange.contains(duration) else {
            error(path, "Duration must be in [\(Self.durationRange.lowerBound), \(Self.durationRange.upperBound)] milliseconds range")
            return nil
        }
        return duration
    }

    /// `'hyprland'`, `'ease-out'`, `'linear'`, `'spring'`, `[x1, y1, x2, y2]` or `{ response = 0.3, damping = 1.0 }`.
    private mutating func parseCurve(_ value: TOMLValue, _ path: ConfigKeyPath) -> AnimationCurve? {
        switch value {
            case .string(let name):
                switch name {
                    case "hyprland": return .hyprland
                    case "ease-out": return .easeOut
                    case "linear": return .linear
                    case "spring": return .defaultSpring
                    default:
                        error(path, "Can't parse curve '\(name)'.\n" +
                            "Possible values: (hyprland|ease-out|linear|spring), [x1, y1, x2, y2] or { response, damping }")
                        return nil
                }
            case .array(let elements):
                guard elements.count == 4 else {
                    error(path, "A bezier curve must have exactly 4 numbers: [x1, y1, x2, y2]")
                    return nil
                }
                var points: [Double] = []
                for (index, element) in elements.enumerated() {
                    guard let point = number(element, path + index) else { return nil }
                    points.append(point)
                }
                guard (0 ... 1).contains(points[0]), (0 ... 1).contains(points[2]) else {
                    error(path, "Bezier x1 and x2 must be in [0, 1] range")
                    return nil
                }
                return .bezier(points[0], points[1], points[2], points[3])
            case .table:
                guard case .spring(var response, var damping) = AnimationCurve.defaultSpring else { return nil }
                for (key, value) in value.sortedEntries {
                    let path = path + key
                    switch key {
                        case "response": assign(&response, springParameter(value, path))
                        case "damping": assign(&damping, springParameter(value, path))
                        default: unknownKey(path)
                    }
                }
                return .spring(response: response, damping: damping)
            default:
                typeMismatch(expected: [.string, .array, .table], actual: value.type, path)
                return nil
        }
    }

    private mutating func springParameter(_ value: TOMLValue, _ path: ConfigKeyPath) -> Double? {
        number(value, path).flatMap { checkRange($0, Self.springParameterRange, path) }
    }

    mutating func parseBorders(_ value: TOMLValue, _ path: ConfigKeyPath) -> BorderConfig {
        var borders = BorderConfig()
        guard let entries = table(value, path) else { return borders }
        for (key, value) in entries {
            let path = path + key
            switch key {
                case "enabled": assign(&borders.enabled, bool(value, path))
                case "width": assign(&borders.width, number(value, path).flatMap { checkRange($0, Self.borderWidthRange, path) })
                case "radius": assign(&borders.radius, borderRadius(value, path))
                case "active-color": assign(&borders.activeColor, color(value, path))
                default: unknownKey(path)
            }
        }
        return borders
    }

    /// `'auto'` (nil) or a number of points.
    private mutating func borderRadius(_ value: TOMLValue, _ path: ConfigKeyPath) -> Double?? {
        switch value {
            case .string("auto"): return .some(nil)
            case .string(let raw):
                error(path, "Can't parse radius '\(raw)'. Expected 'auto' or a number")
                return nil
            case .int, .float: return number(value, path).flatMap { checkRange($0, Self.borderRadiusRange, path) }.map { .some($0) }
            default:
                typeMismatch(expected: [.string, .int, .float], actual: value.type, path)
                return nil
        }
    }

    private mutating func checkRange(_ value: Double, _ range: ClosedRange<Double>, _ path: ConfigKeyPath) -> Double? {
        guard range.contains(value) else {
            error(path, "Must be in [\(String(format: "%g", range.lowerBound)), \(String(format: "%g", range.upperBound))] range")
            return nil
        }
        return value
    }

    private mutating func color(_ value: TOMLValue, _ path: ConfigKeyPath) -> RGBAColor? {
        guard let raw = string(value, path) else { return nil }
        guard let color = RGBAColor(hex: raw) else {
            error(path, "Can't parse color '\(raw)'. Expected '#RRGGBB', '#RRGGBBAA' or '0xAARRGGBB'")
            return nil
        }
        return color
    }
}

extension RGBAColor {
    /// `#RRGGBB`, `#RRGGBBAA` (CSS) or `0xAARRGGBB` (JankyBorders).
    public init?(hex: String) {
        let digits: Substring
        let alphaFirst: Bool
        if hex.hasPrefix("#"), hex.count == 7 || hex.count == 9 {
            digits = hex.dropFirst()
            alphaFirst = false
        } else if hex.lowercased().hasPrefix("0x"), hex.count == 10 {
            digits = hex.dropFirst(2)
            alphaFirst = true
        } else {
            return nil
        }
        guard digits.allSatisfy(\.isHexDigit), var packed = UInt32(digits, radix: 16) else { return nil }
        if digits.count == 6 { packed = packed << 8 | 0xFF }
        if alphaFirst { packed = packed << 8 | packed >> 24 } // AARRGGBB → RRGGBBAA
        func channel(_ shift: UInt32) -> Double { Double(packed >> shift & 0xFF) / 255 }
        self.init(red: channel(24), green: channel(16), blue: channel(8), alpha: channel(0))
    }
}
