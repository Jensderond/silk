import Foundation
@testable import SilkConfig
import Testing

@Suite struct RealConfigTests {
    @Test func userAeroSpaceConfigParsesWithoutDiagnostics() throws {
        let result = parse(try fixture("aerospace"))
        #expect(!result.isFatal)
        #expect(result.diagnostics == [])

        let config = result.config
        #expect(config.configVersion == 2)
        #expect(config.startAtLogin)
        #expect(config.accordionPadding == 30)
        #expect(config.defaultRootContainerLayout == .tiles)
        #expect(config.defaultRootContainerOrientation == .auto)
        #expect(config.afterStartupCommand == CommandScripts(["exec-and-forget ~/.slack-placement.sh"]))
        #expect(config.onFocusedMonitorChanged == CommandScripts(["move-mouse monitor-lazy-center"]))
        #expect(config.persistentWorkspaces == ["1", "2", "3", "4", "5", "6", "7", "8", "9"])
        #expect(config.keyMapping == KeyMapping())
        #expect(config.exec == .fallback)

        for gap in [config.gaps.inner.horizontal, config.gaps.inner.vertical, config.gaps.outer.left,
                    config.gaps.outer.right, config.gaps.outer.top, config.gaps.outer.bottom]
        {
            #expect(gap == .constant(8))
        }

        #expect(config.workspaceToMonitorForceAssignment == ["10": [.nameRegex("built-in")]])

        #expect(config.onWindowDetected.count == 1)
        let slackRule = try #require(config.onWindowDetected.first)
        #expect(slackRule.matcher.appId == "com.tinyspeck.slackmacgap")
        #expect(slackRule.ifCommand == nil)
        #expect(!slackRule.checkFurtherCallbacks)
        #expect(slackRule.run == CommandScripts(["exec-and-forget ~/.slack-placement.sh"]))
    }

    @Test func userAeroSpaceConfigBindings() throws {
        let config = parse(try fixture("aerospace")).config
        #expect(Set(config.modes.keys) == ["main", "service"])

        let main = try #require(config.modes["main"])
        #expect(main.name == "main")
        #expect(main.bindings.count == 82)
        let enter = try #require(main.bindings["alt-enter"])
        #expect(enter.chord == KeyChord(modifiers: [.alt], key: "enter", keyCode: VirtualKey.returnKey))
        #expect(enter.commands == CommandScripts(["exec-and-forget open -n /Applications/Ghostty.app"]))
        #expect(main.bindings["alt-0"]?.commands == CommandScripts(["workspace 10"]))
        #expect(main.bindings["alt-shift-semicolon"]?.commands == CommandScripts(["mode service"]))
        #expect(main.bindings["alt-shift-tab"]?.chord.modifiers == [.alt, .shift])

        let service = try #require(config.modes["service"])
        #expect(service.bindings.count == 9)
        #expect(service.bindings["esc"]?.commands == CommandScripts(["reload-config", "mode main"]))
        #expect(service.bindings["p"]?.commands == CommandScripts(["exec-and-forget ~/.slack-placement.sh", "mode main"]))
        #expect(service.bindings["backspace"]?.chord.keyCode == VirtualKey.delete)
        #expect(service.bindings["alt-shift-l"]?.commands == CommandScripts(["join-with right", "mode main"]))
    }

    @Test func defaultConfigParsesWithoutDiagnostics() throws {
        let url = try #require(ConfigLoader.defaultConfigURL)
        let result = ConfigLoader.parse(try String(contentsOf: url, encoding: .utf8), url: url)
        #expect(result.diagnostics == [])
        #expect(result.config == ConfigLoader.defaultConfig)

        let config = ConfigLoader.defaultConfig
        #expect(config.configVersion == 2)
        #expect(config.persistentWorkspaces.count == 31)
        #expect(config.modes["main"]?.bindings.count == 77)
        #expect(config.modes["service"]?.bindings.count == 8)
        #expect(config.gaps == Gaps())
        #expect(!config.focusFollowsMouse)
        #expect(config.animations == AnimationConfig())
        #expect(config.animations.enabled)
        #expect(!config.borders.enabled)
    }

    @Test func missingConfigFallsBackToDefaultConfig() throws {
        try withTemporaryDirectory { home in
            let result = ConfigLoader.load(home: home, environment: [:])
            #expect(result.url == nil)
            #expect(!result.isFatal)
            #expect(result.diagnostics == [])
            #expect(result.config == ConfigLoader.defaultConfig)
        }
    }
}
