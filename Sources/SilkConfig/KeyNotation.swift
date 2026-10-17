import Foundation

/// Carbon `kVK_*` virtual key codes, hardcoded so SilkConfig stays Foundation-only.
/// Values match `HIToolbox/Events.h` (verified against Carbon in the test suite).
enum VirtualKey {
    static let a: UInt32 = 0x00, s: UInt32 = 0x01, d: UInt32 = 0x02, f: UInt32 = 0x03
    static let h: UInt32 = 0x04, g: UInt32 = 0x05, z: UInt32 = 0x06, x: UInt32 = 0x07
    static let c: UInt32 = 0x08, v: UInt32 = 0x09, isoSection: UInt32 = 0x0A, b: UInt32 = 0x0B
    static let q: UInt32 = 0x0C, w: UInt32 = 0x0D, e: UInt32 = 0x0E, r: UInt32 = 0x0F
    static let y: UInt32 = 0x10, t: UInt32 = 0x11
    static let one: UInt32 = 0x12, two: UInt32 = 0x13, three: UInt32 = 0x14, four: UInt32 = 0x15
    static let six: UInt32 = 0x16, five: UInt32 = 0x17, equal: UInt32 = 0x18, nine: UInt32 = 0x19
    static let seven: UInt32 = 0x1A, minus: UInt32 = 0x1B, eight: UInt32 = 0x1C, zero: UInt32 = 0x1D
    static let rightBracket: UInt32 = 0x1E, o: UInt32 = 0x1F, u: UInt32 = 0x20, leftBracket: UInt32 = 0x21
    static let i: UInt32 = 0x22, p: UInt32 = 0x23, returnKey: UInt32 = 0x24, l: UInt32 = 0x25
    static let j: UInt32 = 0x26, quote: UInt32 = 0x27, k: UInt32 = 0x28, semicolon: UInt32 = 0x29
    static let backslash: UInt32 = 0x2A, comma: UInt32 = 0x2B, slash: UInt32 = 0x2C, n: UInt32 = 0x2D
    static let m: UInt32 = 0x2E, period: UInt32 = 0x2F, tab: UInt32 = 0x30, space: UInt32 = 0x31
    static let grave: UInt32 = 0x32, delete: UInt32 = 0x33, escape: UInt32 = 0x35

    static let keypadDecimal: UInt32 = 0x41, keypadMultiply: UInt32 = 0x43, keypadPlus: UInt32 = 0x45
    static let keypadClear: UInt32 = 0x47, keypadDivide: UInt32 = 0x4B, keypadEnter: UInt32 = 0x4C
    static let keypadMinus: UInt32 = 0x4E, keypadEquals: UInt32 = 0x51
    static let keypad0: UInt32 = 0x52, keypad1: UInt32 = 0x53, keypad2: UInt32 = 0x54, keypad3: UInt32 = 0x55
    static let keypad4: UInt32 = 0x56, keypad5: UInt32 = 0x57, keypad6: UInt32 = 0x58, keypad7: UInt32 = 0x59
    static let keypad8: UInt32 = 0x5B, keypad9: UInt32 = 0x5C

    static let f1: UInt32 = 0x7A, f2: UInt32 = 0x78, f3: UInt32 = 0x63, f4: UInt32 = 0x76
    static let f5: UInt32 = 0x60, f6: UInt32 = 0x61, f7: UInt32 = 0x62, f8: UInt32 = 0x64
    static let f9: UInt32 = 0x65, f10: UInt32 = 0x6D, f11: UInt32 = 0x67, f12: UInt32 = 0x6F
    static let f13: UInt32 = 0x69, f14: UInt32 = 0x6B, f15: UInt32 = 0x71, f16: UInt32 = 0x6A
    static let f17: UInt32 = 0x40, f18: UInt32 = 0x4F, f19: UInt32 = 0x50, f20: UInt32 = 0x5A

    static let home: UInt32 = 0x73, pageUp: UInt32 = 0x74, forwardDelete: UInt32 = 0x75, end: UInt32 = 0x77
    static let pageDown: UInt32 = 0x79
    static let leftArrow: UInt32 = 0x7B, rightArrow: UInt32 = 0x7C, downArrow: UInt32 = 0x7D, upArrow: UInt32 = 0x7E
}

public enum ChordParseError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidModifiers(binding: String)
    case invalidKey(binding: String)

    public var description: String {
        switch self {
            case .invalidModifiers(let binding): "Can't parse modifiers in '\(binding)' binding"
            case .invalidKey(let binding): "Can't parse the key in '\(binding)' binding"
        }
    }
}

/// Key notation (`alt-shift-h`, `keypadEnter`, …) ↔ virtual key codes, ported from AeroSpace's keysMap.swift.
public enum KeyNotation {
    /// Notation → key code for the US (qwerty) layout. This is also the canonical name of every key code.
    public static let qwerty: [String: UInt32] = [
        "sectionSign": VirtualKey.isoSection,
        "0": VirtualKey.zero, "1": VirtualKey.one, "2": VirtualKey.two, "3": VirtualKey.three, "4": VirtualKey.four,
        "5": VirtualKey.five, "6": VirtualKey.six, "7": VirtualKey.seven, "8": VirtualKey.eight, "9": VirtualKey.nine,
        "minus": VirtualKey.minus, "equal": VirtualKey.equal,

        "q": VirtualKey.q, "w": VirtualKey.w, "e": VirtualKey.e, "r": VirtualKey.r, "t": VirtualKey.t,
        "y": VirtualKey.y, "u": VirtualKey.u, "i": VirtualKey.i, "o": VirtualKey.o, "p": VirtualKey.p,
        "leftSquareBracket": VirtualKey.leftBracket, "rightSquareBracket": VirtualKey.rightBracket,
        "backslash": VirtualKey.backslash,

        "a": VirtualKey.a, "s": VirtualKey.s, "d": VirtualKey.d, "f": VirtualKey.f, "g": VirtualKey.g,
        "h": VirtualKey.h, "j": VirtualKey.j, "k": VirtualKey.k, "l": VirtualKey.l,
        "semicolon": VirtualKey.semicolon, "quote": VirtualKey.quote,

        "z": VirtualKey.z, "x": VirtualKey.x, "c": VirtualKey.c, "v": VirtualKey.v, "b": VirtualKey.b,
        "n": VirtualKey.n, "m": VirtualKey.m,
        "comma": VirtualKey.comma, "period": VirtualKey.period, "slash": VirtualKey.slash,

        "keypad0": VirtualKey.keypad0, "keypad1": VirtualKey.keypad1, "keypad2": VirtualKey.keypad2,
        "keypad3": VirtualKey.keypad3, "keypad4": VirtualKey.keypad4, "keypad5": VirtualKey.keypad5,
        "keypad6": VirtualKey.keypad6, "keypad7": VirtualKey.keypad7, "keypad8": VirtualKey.keypad8,
        "keypad9": VirtualKey.keypad9,
        "keypadClear": VirtualKey.keypadClear, "keypadDecimalMark": VirtualKey.keypadDecimal,
        "keypadDivide": VirtualKey.keypadDivide, "keypadEnter": VirtualKey.keypadEnter,
        "keypadEqual": VirtualKey.keypadEquals, "keypadMinus": VirtualKey.keypadMinus,
        "keypadMultiply": VirtualKey.keypadMultiply, "keypadPlus": VirtualKey.keypadPlus,

        "pageUp": VirtualKey.pageUp, "pageDown": VirtualKey.pageDown, "home": VirtualKey.home,
        "end": VirtualKey.end, "forwardDelete": VirtualKey.forwardDelete,

        "f1": VirtualKey.f1, "f2": VirtualKey.f2, "f3": VirtualKey.f3, "f4": VirtualKey.f4, "f5": VirtualKey.f5,
        "f6": VirtualKey.f6, "f7": VirtualKey.f7, "f8": VirtualKey.f8, "f9": VirtualKey.f9, "f10": VirtualKey.f10,
        "f11": VirtualKey.f11, "f12": VirtualKey.f12, "f13": VirtualKey.f13, "f14": VirtualKey.f14,
        "f15": VirtualKey.f15, "f16": VirtualKey.f16, "f17": VirtualKey.f17, "f18": VirtualKey.f18,
        "f19": VirtualKey.f19, "f20": VirtualKey.f20,

        "backtick": VirtualKey.grave, "space": VirtualKey.space, "enter": VirtualKey.returnKey,
        "esc": VirtualKey.escape, "backspace": VirtualKey.delete, "tab": VirtualKey.tab,

        "left": VirtualKey.leftArrow, "down": VirtualKey.downArrow, "up": VirtualKey.upArrow,
        "right": VirtualKey.rightArrow,
    ]

    /// Physical qwerty positions of keys as printed on a Dvorak layout.
    private static let dvorakOverlay: [String: UInt32] = [
        "leftSquareBracket": VirtualKey.minus, "rightSquareBracket": VirtualKey.equal,

        "quote": VirtualKey.q, "comma": VirtualKey.w, "period": VirtualKey.e, "p": VirtualKey.r,
        "y": VirtualKey.t, "f": VirtualKey.y, "g": VirtualKey.u, "c": VirtualKey.i, "r": VirtualKey.o,
        "l": VirtualKey.p, "slash": VirtualKey.leftBracket, "equal": VirtualKey.rightBracket,
        "backslash": VirtualKey.backslash,

        "a": VirtualKey.a, "o": VirtualKey.s, "e": VirtualKey.d, "u": VirtualKey.f, "i": VirtualKey.g,
        "d": VirtualKey.h, "h": VirtualKey.j, "t": VirtualKey.k, "n": VirtualKey.l, "s": VirtualKey.semicolon,
        "minus": VirtualKey.quote,

        "semicolon": VirtualKey.z, "q": VirtualKey.x, "j": VirtualKey.c, "k": VirtualKey.v, "x": VirtualKey.b,
        "b": VirtualKey.n, "m": VirtualKey.m, "w": VirtualKey.comma, "v": VirtualKey.period, "z": VirtualKey.slash,
    ]

    /// Physical qwerty positions of keys as printed on a Colemak layout.
    private static let colemakOverlay: [String: UInt32] = [
        "q": VirtualKey.q, "w": VirtualKey.w, "f": VirtualKey.e, "p": VirtualKey.r, "g": VirtualKey.t,
        "j": VirtualKey.y, "l": VirtualKey.u, "u": VirtualKey.i, "y": VirtualKey.o, "semicolon": VirtualKey.p,
        "leftSquareBracket": VirtualKey.leftBracket, "rightSquareBracket": VirtualKey.rightBracket,
        "backslash": VirtualKey.backslash,

        "a": VirtualKey.a, "r": VirtualKey.s, "s": VirtualKey.d, "t": VirtualKey.f, "d": VirtualKey.g,
        "h": VirtualKey.h, "n": VirtualKey.j, "e": VirtualKey.k, "i": VirtualKey.l, "o": VirtualKey.semicolon,
        "quote": VirtualKey.quote,

        "z": VirtualKey.z, "x": VirtualKey.x, "c": VirtualKey.c, "v": VirtualKey.v, "b": VirtualKey.b,
        "k": VirtualKey.n, "m": VirtualKey.m, "comma": VirtualKey.comma, "period": VirtualKey.period,
        "slash": VirtualKey.slash,
    ]

    private static let dvorak = qwerty.merging(dvorakOverlay) { _, overlay in overlay }
    private static let colemak = qwerty.merging(colemakOverlay) { _, overlay in overlay }

    private static let canonicalNames: [UInt32: String] = Dictionary(uniqueKeysWithValues: qwerty.map { ($1, $0) })

    public static let modifiers: [String: Modifier] = [
        "cmd": .cmd, "alt": .alt, "ctrl": .ctrl, "shift": .shift,
    ]

    /// AeroSpace's canonical modifier order for normalized binding descriptors.
    static let canonicalModifierOrder: [Modifier] = [.alt, .ctrl, .cmd, .shift]

    public static func keyCodes(for preset: KeyMappingPreset) -> [String: UInt32] {
        switch preset {
            case .qwerty: qwerty
            case .dvorak: dvorak
            case .colemak: colemak
        }
    }

    /// The canonical (qwerty) notation of a key code, e.g. `0x24` → `enter`.
    public static func canonicalName(ofKeyCode keyCode: UInt32) -> String? {
        canonicalNames[keyCode]
    }

    /// Parses `alt-shift-h` style chords. The last `-`-separated component is the key, everything before it
    /// must be a modifier (`cmd`, `alt`, `ctrl`, `shift`).
    public static func parseChord(_ raw: String, keyCodes: [String: UInt32]) -> Result<KeyChord, ChordParseError> {
        // Like AeroSpace, empty components are dropped ("alt--h" == "alt-h").
        let components = raw.split(separator: "-").map(String.init)
        var chordModifiers = Set<Modifier>()
        for component in components.dropLast() {
            guard let modifier = modifiers[component] else { return .failure(.invalidModifiers(binding: raw)) }
            chordModifiers.insert(modifier)
        }
        guard let key = components.last, let keyCode = keyCodes[key] else {
            return .failure(.invalidKey(binding: raw))
        }
        return .success(KeyChord(modifiers: chordModifiers, key: key, keyCode: keyCode))
    }

    public static func parseChord(_ raw: String, mapping: KeyMapping = KeyMapping()) -> Result<KeyChord, ChordParseError> {
        parseChord(raw, keyCodes: mapping.resolve())
    }

    /// Valid `key-notation-to-key-code` keys: no whitespace and no `-` (it separates modifiers).
    static func isValidNotation(_ notation: String) -> Bool {
        !notation.isEmpty && notation.rangeOfCharacter(from: .whitespacesAndNewlines) == nil && !notation.contains("-")
    }
}

extension KeyMapping {
    /// The effective notation → key code table: the preset, then `key-notation-to-key-code` overrides.
    public func resolve() -> [String: UInt32] {
        KeyNotation.keyCodes(for: preset).merging(overrides) { _, override in override }
    }
}

extension KeyChord {
    /// Layout-independent descriptor, e.g. `alt-shift-h`: modifiers in AeroSpace order (alt, ctrl, cmd, shift)
    /// followed by the qwerty name of the key code. Two chords with the same descriptor are the same hotkey.
    public var normalizedDescriptor: String {
        let keyName = KeyNotation.canonicalName(ofKeyCode: keyCode) ?? key
        let modifierNames = KeyNotation.canonicalModifierOrder.filter(modifiers.contains).map(\.rawValue)
        return (modifierNames + [keyName]).joined(separator: "-")
    }
}
