import Carbon.HIToolbox
@testable import SilkConfig
import Testing

@Suite struct KeyNotationTests {
    /// Every key name AeroSpace documents, with its Carbon constant.
    static let expectedKeyCodes: [String: Int] = [
        "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E, "f": kVK_ANSI_F,
        "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
        "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R,
        "s": kVK_ANSI_S, "t": kVK_ANSI_T, "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
        "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
        "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4,
        "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
        "keypad0": kVK_ANSI_Keypad0, "keypad1": kVK_ANSI_Keypad1, "keypad2": kVK_ANSI_Keypad2,
        "keypad3": kVK_ANSI_Keypad3, "keypad4": kVK_ANSI_Keypad4, "keypad5": kVK_ANSI_Keypad5,
        "keypad6": kVK_ANSI_Keypad6, "keypad7": kVK_ANSI_Keypad7, "keypad8": kVK_ANSI_Keypad8,
        "keypad9": kVK_ANSI_Keypad9,
        "f1": kVK_F1, "f2": kVK_F2, "f3": kVK_F3, "f4": kVK_F4, "f5": kVK_F5, "f6": kVK_F6, "f7": kVK_F7,
        "f8": kVK_F8, "f9": kVK_F9, "f10": kVK_F10, "f11": kVK_F11, "f12": kVK_F12, "f13": kVK_F13,
        "f14": kVK_F14, "f15": kVK_F15, "f16": kVK_F16, "f17": kVK_F17, "f18": kVK_F18, "f19": kVK_F19,
        "f20": kVK_F20,
        "minus": kVK_ANSI_Minus, "equal": kVK_ANSI_Equal, "period": kVK_ANSI_Period, "comma": kVK_ANSI_Comma,
        "slash": kVK_ANSI_Slash, "backslash": kVK_ANSI_Backslash, "quote": kVK_ANSI_Quote,
        "semicolon": kVK_ANSI_Semicolon, "backtick": kVK_ANSI_Grave,
        "leftSquareBracket": kVK_ANSI_LeftBracket, "rightSquareBracket": kVK_ANSI_RightBracket,
        "space": kVK_Space, "enter": kVK_Return, "esc": kVK_Escape, "backspace": kVK_Delete, "tab": kVK_Tab,
        "pageUp": kVK_PageUp, "pageDown": kVK_PageDown, "home": kVK_Home, "end": kVK_End,
        "forwardDelete": kVK_ForwardDelete, "sectionSign": kVK_ISO_Section,
        "keypadClear": kVK_ANSI_KeypadClear, "keypadDecimalMark": kVK_ANSI_KeypadDecimal,
        "keypadDivide": kVK_ANSI_KeypadDivide, "keypadEnter": kVK_ANSI_KeypadEnter,
        "keypadEqual": kVK_ANSI_KeypadEquals, "keypadMinus": kVK_ANSI_KeypadMinus,
        "keypadMultiply": kVK_ANSI_KeypadMultiply, "keypadPlus": kVK_ANSI_KeypadPlus,
        "left": kVK_LeftArrow, "down": kVK_DownArrow, "up": kVK_UpArrow, "right": kVK_RightArrow,
    ]

    @Test func qwertyTableMatchesCarbon() {
        #expect(KeyNotation.qwerty == Self.expectedKeyCodes.mapValues(UInt32.init))
    }

    @Test(arguments: expectedKeyCodes.keys.sorted())
    func parsesChordForEveryKey(_ key: String) throws {
        let keyCode = UInt32(try #require(Self.expectedKeyCodes[key]))
        #expect(try KeyNotation.parseChord(key).get() == KeyChord(modifiers: [], key: key, keyCode: keyCode))

        let chord = try KeyNotation.parseChord("cmd-alt-ctrl-shift-\(key)").get()
        #expect(chord == KeyChord(modifiers: [.cmd, .alt, .ctrl, .shift], key: key, keyCode: keyCode))
        #expect(chord.normalizedDescriptor == "alt-ctrl-cmd-shift-\(key)")
        #expect(KeyNotation.canonicalName(ofKeyCode: keyCode) == key)
    }

    @Test func chordErrors() {
        #expect(KeyNotation.parseChord("alt-hh") == .failure(.invalidKey(binding: "alt-hh")))
        #expect(KeyNotation.parseChord("aalt-j") == .failure(.invalidModifiers(binding: "aalt-j")))
        #expect(KeyNotation.parseChord("") == .failure(.invalidKey(binding: "")))
        #expect(KeyNotation.parseChord("alt-") == .failure(.invalidKey(binding: "alt-")))
        #expect(KeyNotation.parseChord("Alt-h") == .failure(.invalidModifiers(binding: "Alt-h")))
        #expect(ChordParseError.invalidKey(binding: "alt-hh").description == "Can't parse the key in 'alt-hh' binding")
    }

    @Test func chordModifiers() throws {
        let chord = try KeyNotation.parseChord("shift-alt-h").get()
        #expect(chord.modifiers == [.alt, .shift])
        #expect(chord.key == "h")
        #expect(chord.normalizedDescriptor == "alt-shift-h")
        #expect(try KeyNotation.parseChord("ctrl-cmd-left").get().normalizedDescriptor == "ctrl-cmd-left")
    }

    @Test func presetsAndOverrides() throws {
        var mapping = KeyMapping()
        mapping.preset = .dvorak
        #expect(try KeyNotation.parseChord("alt-quote", mapping: mapping).get().keyCode == UInt32(kVK_ANSI_Q))
        #expect(try KeyNotation.parseChord("alt-s", mapping: mapping).get().keyCode == UInt32(kVK_ANSI_Semicolon))
        #expect(try KeyNotation.parseChord("enter", mapping: mapping).get().keyCode == UInt32(kVK_Return))

        mapping.preset = .colemak
        #expect(try KeyNotation.parseChord("alt-o", mapping: mapping).get().keyCode == UInt32(kVK_ANSI_Semicolon))

        mapping.overrides = ["unicorn": UInt32(kVK_ANSI_U), "o": UInt32(kVK_ANSI_O)]
        #expect(try KeyNotation.parseChord("alt-unicorn", mapping: mapping).get().keyCode == UInt32(kVK_ANSI_U))
        #expect(try KeyNotation.parseChord("alt-o", mapping: mapping).get().keyCode == UInt32(kVK_ANSI_O), "overrides win over the preset")
    }
}
