@testable import SilkConfig
import Testing

@Suite struct SilkExtensionTests {
    @Test func defaults() {
        let config = parse("config-version = 2").config
        #expect(config.focusBackend == .appkit)
        #expect(config.animations.enabled)
        #expect(config.animations.duration == 180)
        #expect(config.animations.curve == .easeOut)
        #expect(config.animations.windowOpen == .move)
        #expect(config.animations.workspaceSwitch == .slide)
        #expect(config.animations.workspaceDuration == 220)
        #expect(config.animations.respectReduceMotion)
        #expect(!config.borders.enabled)
        #expect(config.borders.radius == nil)
    }

    @Test func focusBackend() {
        #expect(parse("focus-backend = 'skylight'").config.focusBackend == .skylight)
        #expect(parse("focus-backend = 'cgs'").errorDescriptions == [
            "[ERROR] focus-backend: Can't parse 'cgs'.\nPossible values: (appkit|skylight)",
        ])
    }

    @Test func animations() {
        let result = parse("""
            config-version = 2
            [animations]
                enabled = false
                duration = 0
                curve = [0.2, 0.9, 0.1, 1.1]
                window-open = 'popin'
                workspace-switch = 'none'
                workspace-duration = 2000
                respect-reduce-motion = false
            """)
        #expect(result.diagnostics == [])
        let animations = result.config.animations
        #expect(!animations.enabled)
        #expect(animations.duration == 0)
        #expect(animations.curve == .bezier(0.2, 0.9, 0.1, 1.1))
        #expect(animations.windowOpen == .popin)
        #expect(animations.workspaceSwitch == .none)
        #expect(animations.workspaceDuration == 2000)
        #expect(!animations.respectReduceMotion)
    }

    @Test(arguments: [
        ("'hyprland'", AnimationCurve.hyprland),
        ("'ease-out'", .easeOut),
        ("'linear'", .linear),
        ("'spring'", .defaultSpring),
        ("[0, 0, 1, 1]", .bezier(0, 0, 1, 1)),
        ("{ response = 0.5, damping = 0.8 }", .spring(response: 0.5, damping: 0.8)),
        ("{ damping = 0.7 }", .spring(response: 0.3, damping: 0.7)),
    ])
    func curves(_ toml: String, _ expected: AnimationCurve) {
        let result = parse("animations.curve = \(toml)")
        #expect(result.errors == [])
        #expect(result.config.animations.curve == expected)
    }

    @Test func animationErrors() {
        let result = parse("""
            [animations]
                duration = 2001
                workspace-duration = -1
                window-open = 'fade'
                speed = 2
            """)
        #expect(result.errorDescriptions == [
            "[ERROR] animations.duration: Duration must be in [0, 2000] milliseconds range",
            "[ERROR] animations.speed: Unknown key",
            "[ERROR] animations.window-open: Can't parse 'fade'.\nPossible values: (move|popin|none)",
            "[ERROR] animations.workspace-duration: Duration must be in [0, 2000] milliseconds range",
        ])
        #expect(result.config.animations == AnimationConfig())

        #expect(parse("animations.curve = 'bounce'").errorDescriptions == [
            "[ERROR] animations.curve: Can't parse curve 'bounce'.\n" +
                "Possible values: (hyprland|ease-out|linear|spring), [x1, y1, x2, y2] or { response, damping }",
        ])
        #expect(parse("animations.curve = [1, 2, 3]").errorDescriptions == [
            "[ERROR] animations.curve: A bezier curve must have exactly 4 numbers: [x1, y1, x2, y2]",
        ])
        #expect(parse("animations.curve = [1.5, 0, 0.5, 1]").errorDescriptions == [
            "[ERROR] animations.curve: Bezier x1 and x2 must be in [0, 1] range",
        ])
        #expect(parse("animations.curve = [0, 'a', 0.5, 1]").errorDescriptions == [
            "[ERROR] animations.curve[1]: Expected types are 'Int' or 'Float'. But actual type is 'String'",
        ])
        #expect(parse("animations.curve = { response = 0, stiffness = 1 }").errorDescriptions == [
            "[ERROR] animations.curve.response: Must be in [0.01, 5] range",
            "[ERROR] animations.curve.stiffness: Unknown key",
        ])
        #expect(parse("animations.curve = true").errorDescriptions == [
            "[ERROR] animations.curve: Expected types are 'String' or 'Array' or 'Table'. But actual type is 'Bool'",
        ])
        #expect(parse("animations.duration = 180.0").errorDescriptions == [
            "[ERROR] animations.duration: Expected type is 'Int'. But actual type is 'Float'",
        ])
    }

    @Test func borders() {
        let result = parse("""
            [borders]
                enabled = true
                width = 3.5
                active-color = '0xffe1e3e4'
                radius = 10
            """)
        #expect(result.diagnostics.filter { $0.severity == .error } == [])
        let borders = result.config.borders
        #expect(borders.enabled)
        #expect(borders.width == 3.5)
        #expect(borders.activeColor == RGBAColor(red: 0xE1 / 255, green: 0xE3 / 255, blue: 0xE4 / 255, alpha: 1))
        #expect(borders.radius == 10)

        #expect(parse("borders.radius = 'auto'").config.borders.radius == nil)
        #expect(parse("borders.radius = 12\nborders.width = 0").config.borders.radius == 12)
    }

    @Test func borderErrors() {
        let result = parse("""
            [borders]
                width = 21
                radius = 'round'
                active-color = 'blue'
                inactive = 1
            """)
        #expect(result.errorDescriptions == [
            "[ERROR] borders.active-color: Can't parse color 'blue'. Expected '#RRGGBB', '#RRGGBBAA' or '0xAARRGGBB'",
            "[ERROR] borders.inactive: Unknown key",
            "[ERROR] borders.radius: Can't parse radius 'round'. Expected 'auto' or a number",
            "[ERROR] borders.width: Must be in [0, 20] range",
        ])
        #expect(parse("borders.radius = 65").errorDescriptions == ["[ERROR] borders.radius: Must be in [0, 64] range"])
        #expect(parse("borders.radius = true").errorDescriptions == [
            "[ERROR] borders.radius: Expected types are 'String' or 'Int' or 'Float'. But actual type is 'Bool'",
        ])
    }

    @Test(arguments: [
        ("#89b4fa", RGBAColor(red: 0x89 / 255, green: 0xB4 / 255, blue: 0xFA / 255, alpha: 1)),
        ("#89B4FA80", RGBAColor(red: 0x89 / 255, green: 0xB4 / 255, blue: 0xFA / 255, alpha: 0x80 / 255)),
        ("0x8089b4fa", RGBAColor(red: 0x89 / 255, green: 0xB4 / 255, blue: 0xFA / 255, alpha: 0x80 / 255)),
        ("0XFF000000", RGBAColor(red: 0, green: 0, blue: 0, alpha: 1)),
        ("#ffffff00", RGBAColor(red: 1, green: 1, blue: 1, alpha: 0)),
    ])
    func validColors(_ hex: String, _ expected: RGBAColor) {
        #expect(RGBAColor(hex: hex) == expected)
    }

    @Test(arguments: ["89b4fa", "#89b4f", "#89b4fa8", "#gggggg", "0x89b4fa", "#+9b4fa", "0x-089b4fa", "", "#"])
    func invalidColors(_ hex: String) {
        #expect(RGBAColor(hex: hex) == nil)
    }
}
