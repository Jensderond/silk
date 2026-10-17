import Foundation
@testable import SilkConfig
import Testing

@Suite struct SchemaTests {
    @Test func emptyConfigWarnsAboutConfigVersion() {
        let result = parse("")
        #expect(result.errors == [])
        #expect(!result.isFatal)
        #expect(result.warnings.count == 1)
        #expect(result.warnings.first?.description.hasPrefix("[WARNING] The current 'config-version = 1' is outdated.") == true)
        #expect(result.config.modes == ["main": Mode(name: "main")])
        #expect(result.config.exec == .fallback)
    }

    @Test func configVersion() {
        #expect(parse("config-version = 0").errorDescriptions == ["[ERROR] config-version: config-version must be in [1, 2] range"])
        #expect(parse("config-version = 3").errorDescriptions == ["[ERROR] config-version: config-version must be in [1, 2] range"])
        #expect(parse("config-version = 2").diagnostics == [])
    }

    @Test func persistentWorkspacesRequireConfigVersion2() {
        #expect(parse("persistent-workspaces = ['a']").errorDescriptions == [
            "[ERROR] persistent-workspaces: This config option is only available since 'config-version = 2'",
        ])
        #expect(parse("config-version = 2\npersistent-workspaces = ['a', 'a']").errorDescriptions == [
            "[ERROR] persistent-workspaces: Contains duplicated workspace names",
        ])
        let valid = parse("config-version = 2\npersistent-workspaces = ['b', 'a']")
        #expect(valid.errors == [])
        #expect(valid.config.persistentWorkspaces == ["b", "a"])
    }

    @Test func configVersion1InfersPersistentWorkspacesFromBindings() {
        let result = parse("""
            [mode.main.binding]
                alt-1 = 'workspace 1'
                alt-2 = 'workspace --auto-back-and-forth 2'
                alt-3 = ['workspace 3']
                alt-4 = ['workspace 4', 'focus left']
                alt-5 = 'move-node-to-workspace --window-id 42 --focus-follows-window "five"; workspace next'
                alt-6 = 'workspace -- next'
                alt-7 = 'workspace --wrap-around prev'
            [workspace-to-monitor-force-assignment]
                W = 'main'
            """)
        #expect(result.errors == [])
        #expect(result.config.persistentWorkspaces == ["1", "2", "3", "4", "five", "next", "W"])
    }

    @Test func unknownKeys() {
        let result = parse("""
            unknownKey = true
            enable-normalization-flatten-containers = false
            [gaps]
                unknownKey = true
            [mode.main]
                bindings = {}
            """)
        #expect(result.errorDescriptions == [
            "[ERROR] gaps.unknownKey: Unknown key",
            "[ERROR] mode.main.bindings: Unknown key",
            "[ERROR] unknownKey: Unknown top-level key",
        ])
        #expect(!result.isFatal)
        #expect(result.config.enableNormalizationFlattenContainers == false)
    }

    @Test func typeMismatches() {
        #expect(parse("enable-normalization-flatten-containers = 'true'").errorDescriptions == [
            "[ERROR] enable-normalization-flatten-containers: Expected type is 'Bool'. But actual type is 'String'",
        ])
        #expect(parse("exec-on-workspace-change = ['', 1]").errorDescriptions == [
            "[ERROR] exec-on-workspace-change[1]: Expected type is 'String'. But actual type is 'Int'",
        ])
        #expect(parse("accordion-padding = 1.5").errorDescriptions == [
            "[ERROR] accordion-padding: Expected type is 'Int'. But actual type is 'Float'",
        ])
        #expect(parse("on-focus-changed = 1").errorDescriptions == [
            "[ERROR] on-focus-changed: Expected types are 'String' or 'Array'. But actual type is 'Int'",
        ])
        #expect(parse("[mode.main.binding]\nalt-a = [1, 'focus right']").errorDescriptions == [
            "[ERROR] mode.main.binding.alt-a[0]: Expected type is 'String'. But actual type is 'Int'",
        ])
        #expect(parse("gaps = 5").errorDescriptions == ["[ERROR] gaps: Expected type is 'Table'. But actual type is 'Int'"])
        #expect(parse("foo.bar = 1979-05-27").errorDescriptions == [
            "[ERROR] foo.bar: Unsupported TOML type: LocalDate",
            "[ERROR] foo: Unknown top-level key",
        ])
    }

    @Test func invalidValueKeepsDefault() {
        let result = parse("accordion-padding = 'wide'\nstart-at-login = true")
        #expect(result.config.accordionPadding == 30)
        #expect(result.config.startAtLogin)
    }

    @Test func tomlSyntaxErrorIsFatalWithLineNumber() {
        let result = parse("config-version = 2\n\nfoo: 1")
        #expect(result.isFatal)
        #expect(result.errorDescriptions == ["[ERROR] (Line 3) Syntax error: missing =."])
        #expect(result.config == ConfigLoader.defaultConfig)

        #expect(parse("[[[on-window-detected]]\nrun = 'layout floating'").errorDescriptions == [
            "[ERROR] (Line 1) Syntax error: invalid or missing key.",
        ])
    }

    @Test func scalarKeys() {
        let result = parse("""
            config-version = 2
            after-startup-command = 'workspace 1'
            after-login-command = []
            start-at-login = true
            auto-reload-config = true
            automatically-unhide-macos-hidden-apps = true
            enable-normalization-flatten-containers = false
            enable-normalization-opposite-orientation-for-nested-containers = false
            accordion-padding = 0
            default-root-container-layout = 'accordion'
            default-root-container-orientation = 'vertical'
            exec-on-workspace-change = ['/bin/bash', '-c', 'echo $AEROSPACE_FOCUSED_WORKSPACE']
            on-focus-changed = 'move-mouse window-lazy-center'
            on-mode-changed = ['focus right', 'focus up']
            focus-follows-mouse.enabled = true
            """)
        #expect(result.diagnostics == [])
        let config = result.config
        #expect(config.afterStartupCommand == CommandScripts(["workspace 1"]))
        #expect(config.startAtLogin && config.autoReloadConfig && config.automaticallyUnhideMacosHiddenApps)
        #expect(!config.enableNormalizationFlattenContainers)
        #expect(!config.enableNormalizationOppositeOrientationForNestedContainers)
        #expect(config.accordionPadding == 0)
        #expect(config.defaultRootContainerLayout == .accordion)
        #expect(config.defaultRootContainerOrientation == .vertical)
        #expect(config.execOnWorkspaceChange == ["/bin/bash", "-c", "echo $AEROSPACE_FOCUSED_WORKSPACE"])
        #expect(config.onFocusChanged == CommandScripts(["move-mouse window-lazy-center"]))
        #expect(config.onModeChanged == CommandScripts(["focus right", "focus up"]))
        #expect(config.focusFollowsMouse)
    }

    @Test func layoutAndOrientation() {
        #expect(parse("default-root-container-layout = 'list'").config.defaultRootContainerLayout == .tiles)
        #expect(parse("default-root-container-layout = 'bogus'").errorDescriptions == [
            "[ERROR] default-root-container-layout: Can't parse layout 'bogus'",
        ])
        #expect(parse("default-root-container-orientation = 'diagonal'").errorDescriptions == [
            "[ERROR] default-root-container-orientation: Can't parse default container orientation 'diagonal'",
        ])
    }

    @Test func focusFollowsMouseMustBeTable() {
        #expect(parse("focus-follows-mouse = true").errorDescriptions == [
            "[ERROR] focus-follows-mouse: Expected type is 'Table'. But actual type is 'Bool'",
        ])
        #expect(parse("focus-follows-mouse.enable = true").errorDescriptions == ["[ERROR] focus-follows-mouse.enable: Unknown key"])
    }

    @Test func deprecatedKeys() {
        #expect(parse("after-login-command = ['exec-and-forget echo hi']").errorDescriptions == [
            "[ERROR] after-login-command: after-login-command is deprecated since AeroSpace 0.19.0. https://github.com/nikitabobko/AeroSpace/issues/1482",
        ])
        #expect(parse("non-empty-workspaces-root-containers-layout-on-startup = 'smart'").errors == [])
        #expect(parse("non-empty-workspaces-root-containers-layout-on-startup = 'tiles'").errorDescriptions == [
            "[ERROR] non-empty-workspaces-root-containers-layout-on-startup: 'non-empty-workspaces-root-containers-layout-on-startup' is deprecated. Please drop it from your config",
        ])
        #expect(parse("indent-for-nested-containers-with-the-same-orientation = 30").errorDescriptions == [
            "[ERROR] indent-for-nested-containers-with-the-same-orientation: Deprecated. Please drop it from the config. See https://github.com/nikitabobko/AeroSpace/issues/96",
        ])
    }

    @Test func splitCommandConflictsWithFlattenNormalization() {
        let result = parse("""
            enable-normalization-flatten-containers = true
            [mode.main.binding]
            [mode.foo.binding]
                alt-s = 'split horizontal'
            """)
        #expect(result.errors.count == 1)
        #expect(result.errors.first?.keyPath == "")
        #expect(result.errors.first?.message.hasPrefix("The config contains:\n1. usage of 'split' command") == true)
        #expect(parse("enable-normalization-flatten-containers = false\nmode.main.binding.alt-s = 'split horizontal'").errors == [])
    }

    // MARK: Modes and bindings

    @Test func modes() {
        let dropped = parse("mode.main = {}")
        #expect(dropped.errors == [])
        #expect(dropped.config.modes["main"]?.bindings.isEmpty == true)

        let missingMain = parse("[mode.foo.binding]\nalt-h = 'focus left'")
        #expect(missingMain.errorDescriptions == ["[ERROR] mode: Please specify 'main' mode"])
        #expect(missingMain.config.modes["main"] == Mode(name: "main"), "'main' always exists")
        #expect(missingMain.config.modes["foo"]?.bindings["alt-h"] != nil)
    }

    @Test func bindingParseErrors() {
        let result = parse("""
            [mode.main.binding]
                alt-hh = 'focus left'
                aalt-j = 'focus down'
                alt-k = 'focus up'
            """)
        #expect(result.errorDescriptions == [
            "[ERROR] mode.main.binding.aalt-j: Can't parse modifiers in 'aalt-j' binding",
            "[ERROR] mode.main.binding.alt-hh: Can't parse the key in 'alt-hh' binding",
        ])
        #expect(Array(result.config.modes["main"]!.bindings.keys) == ["alt-k"])
    }

    @Test func bindingRedeclarationAndNormalizedLookup() {
        let result = parse("""
            [mode.main.binding]
                alt-shift-h = 'move left'
                shift-alt-h = 'move right'
                ctrl-cmd-alt-shift-enter = 'focus up'
            """)
        #expect(result.errorDescriptions == ["[ERROR] mode.main.binding.shift-alt-h: 'alt-shift-h' Binding redeclaration"])
        let main = result.config.modes["main"]!
        #expect(Set(main.bindings.keys) == ["shift-alt-h", "ctrl-cmd-alt-shift-enter"])
        #expect(main.binding(named: "shift-alt-h")?.commands == CommandScripts(["move right"]))
        #expect(main.binding(named: "alt-shift-h")?.descriptor == "shift-alt-h")
        #expect(main.binding(named: "alt-shift-j") == nil)
    }

    // MARK: Gaps and monitors

    @Test func perMonitorGaps() {
        let result = parse("""
            [gaps]
                inner.horizontal = 10
                inner.vertical = [{ monitor."main" = 1 }, { monitor."secondary" = 2 }, 5]
                outer.left = 12
                outer.bottom = 13
                outer.top = [{ monitor.main = 16 }, { monitor."some-pattern" = 32 }, 24]
                outer.right = [{ monitor.2 = 7 }, { monitor.built-in = 3 }, 8]
            """)
        #expect(result.errors == [])
        let gaps = result.config.gaps
        #expect(gaps.inner.horizontal == .constant(10))
        #expect(gaps.inner.vertical == .perMonitor([.init(monitor: .main, value: 1), .init(monitor: .secondary, value: 2)], default: 5))
        #expect(gaps.outer.left == .constant(12))
        #expect(gaps.outer.bottom == .constant(13))
        #expect(gaps.outer.top == .perMonitor([.init(monitor: .main, value: 16), .init(monitor: .nameRegex("some-pattern"), value: 32)], default: 24))
        #expect(gaps.outer.right == .perMonitor([.init(monitor: .sequenceNumber(2), value: 7), .init(monitor: .nameRegex("built-in"), value: 3)], default: 8))
    }

    @Test func perMonitorGapErrors() {
        let result = parse("""
            [gaps]
                inner.horizontal = [true]
                inner.vertical = [{ foo.main = 1 }, { monitor = { foo = 2, bar = 3 } }, 1]
                outer.left = []
                outer.right = [4]
                outer.top = [{ monitor.main = 'x' }, { monitor.0 = 1 }, 2]
                outer.bottom = 'x'
            """)
        #expect(result.errorDescriptions == [
            "[ERROR] gaps.inner.horizontal: The last item in the array must be of type Int",
            "[ERROR] gaps.inner.vertical[0]: The table is expected to have a single key 'monitor'",
            "[ERROR] gaps.inner.vertical[1].monitor: The table is expected to have a single key",
            "[ERROR] gaps.outer.bottom: Unsupported type: String, expected: Int or array",
            "[ERROR] gaps.outer.left: The array must not be empty",
            "[ERROR] gaps.outer.right: The array must contain at least one monitor pattern",
            "[ERROR] gaps.outer.top[0].monitor.main: Expected type is 'Int'. But actual type is 'String'",
            "[ERROR] gaps.outer.top[1].monitor.0: Monitor sequence numbers uses 1-based indexing. Values less than 1 are illegal",
        ])
        #expect(result.config.gaps.outer.top == .perMonitor([], default: 2))
    }

    @Test func workspaceToMonitorForceAssignment() {
        let result = parse("""
            [workspace-to-monitor-force-assignment]
                workspace_name_1 = 1
                workspace_name_2 = 'main'
                workspace_name_3 = 'secondary'
                workspace_name_4 = 'built-in'
                workspace_name_5 = '^built-in retina display$'
                workspace_name_6 = ['secondary', 1]
                7 = "foo"
                w7 = ['', 'main']
                w8 = 0
                w9 = '('
                workspace_name_x = '2'
            """)
        #expect(result.config.workspaceToMonitorForceAssignment == [
            "workspace_name_1": [.sequenceNumber(1)],
            "workspace_name_2": [.main],
            "workspace_name_3": [.secondary],
            "workspace_name_4": [.nameRegex("built-in")],
            "workspace_name_5": [.nameRegex("^built-in retina display$")],
            "workspace_name_6": [.secondary, .sequenceNumber(1)],
            "workspace_name_x": [.sequenceNumber(2)],
            "7": [.nameRegex("foo")],
            "w7": [.main],
            "w8": [],
            "w9": [],
        ])
        #expect(result.errorDescriptions.count == 3)
        #expect(result.errorDescriptions[0] == "[ERROR] workspace-to-monitor-force-assignment.w7[0]: Empty string is an illegal monitor description")
        #expect(result.errorDescriptions[1] == "[ERROR] workspace-to-monitor-force-assignment.w8: Monitor sequence numbers uses 1-based indexing. Values less than 1 are illegal")
        #expect(result.errorDescriptions[2].hasPrefix("[ERROR] workspace-to-monitor-force-assignment.w9: Can't parse '(' regex: "))
    }

    // MARK: on-window-detected

    @Test func onWindowDetected() {
        let result = parse("""
            on-window-detected = [
                { # 0
                    if = 'true',
                    check-further-callbacks = true,
                    run = ['layout floating', 'move-node-to-workspace W'],
                },
                { # 1
                    if.app-id = 'com.apple.systempreferences',
                    if.app-name-regex-substring = '^system settings$',
                    if.window-title-regex-substring = 'general',
                    if.workspace = 'S',
                    if.during-aerospace-startup = false,
                    run = [],
                },
                {}, # 2
                { # 3
                    if = 'test %{app-bundle-id} = org.alacritty',
                    run = 'move-node-to-workspace T',
                },
                { if = '', run = ''}, # 4
                { check-further-callbacks = true, run = 'layout floating' }, # 5
                { if.app-name-regex-substring = '(', run = 'layout floating' }, # 6
                { if = 1, run = 'layout floating', foo = 1 }, # 7
            ]
            """)
        var rule0 = WindowDetectedRule()
        rule0.ifCommand = "true"
        rule0.checkFurtherCallbacks = true
        rule0.run = CommandScripts(["layout floating", "move-node-to-workspace W"])

        var rule1 = WindowDetectedRule()
        rule1.matcher.appId = "com.apple.systempreferences"
        rule1.matcher.appNameRegexSubstring = "^system settings$"
        rule1.matcher.windowTitleRegexSubstring = "general"
        rule1.matcher.workspace = "S"
        rule1.matcher.duringStartup = false

        var rule3 = WindowDetectedRule()
        rule3.ifCommand = "test %{app-bundle-id} = org.alacritty"
        rule3.run = CommandScripts(["move-node-to-workspace T"])

        var rule5 = WindowDetectedRule()
        rule5.checkFurtherCallbacks = true
        rule5.run = CommandScripts(["layout floating"])

        #expect(result.config.onWindowDetected == [rule0, rule1, rule3, rule5])

        let omittedIf = "Omitting 'if' is error prone. You can use `if = 'true'` to preserve the previous behavior.\n" +
            "But heads up! You may have missed 'check-further-callbacks = true'"
        let errors = result.errorDescriptions
        #expect(errors.count == 7)
        #expect(errors[0] == "[ERROR] on-window-detected[2]: \(omittedIf)")
        #expect(errors[1] == "[ERROR] on-window-detected[2]: 'run' is mandatory key")
        #expect(errors[2] == "[ERROR] on-window-detected[4]: \(omittedIf)")
        #expect(errors[3].hasPrefix("[ERROR] on-window-detected[6].if.app-name-regex-substring: Can't parse '(' regex: "))
        #expect(errors[4] == "[ERROR] on-window-detected[7].foo: Unknown key")
        #expect(errors[5] == "[ERROR] on-window-detected[7].if: Expected type is 'String'. But actual type is 'Int'")
        #expect(errors[6] == "[ERROR] on-window-detected[7]: \(omittedIf)")
    }

    @Test func onWindowDetectedArrayOfTables() {
        let result = parse("""
            [[on-window-detected]]
                if.app-id = 'com.tinyspeck.slackmacgap'
                run = 'move-node-to-workspace 10'

            [[on-window-detected]]
                if = 'test %{app-bundle-id} = com.apple.finder'
                check-further-callbacks = true
                run = ['layout floating']
            """)
        #expect(result.errors == [])
        #expect(result.config.onWindowDetected.map(\.matcher.appId) == ["com.tinyspeck.slackmacgap", nil])
        #expect(result.config.onWindowDetected.map(\.ifCommand) == [nil, "test %{app-bundle-id} = com.apple.finder"])
    }

    // MARK: exec

    @Test func exec() {
        let inheritOff = parse("exec.inherit-env-vars = false")
        #expect(inheritOff.errors == [])
        #expect(inheritOff.config.exec.inheritEnvVars == false)
        #expect(inheritOff.config.exec.env == [:], "An explicit [exec] table drops the Homebrew PATH fallback")

        let overrides = parse("""
            [exec.env-vars]
                PATH = '${HOME}/bin:${PATH}'
                FOO = 'BAR'
            """)
        #expect(overrides.errors == [])
        #expect(overrides.config.exec.env == ["PATH": "${HOME}/bin:${PATH}", "FOO": "BAR"])
        let environment = overrides.config.exec.environment(processEnvironment: ["HOME": "/Users/me", "PATH": "/usr/bin", "LANG": "nl"])
        #expect(environment == ["HOME": "/Users/me", "PATH": "/Users/me/bin:/usr/bin", "FOO": "BAR", "LANG": "nl"])

        #expect(ExecConfig.fallback.environment(processEnvironment: ["PATH": "/usr/bin"]) == [
            "PATH": "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/bin",
        ])
    }

    @Test func execErrors() {
        let unavailable = "isn't presented in Silk env vars, or not available for interpolation (because it's mutated)"
        #expect(parse("[exec.env-vars]\nFOO = '${BAR}'\nBAR = '${FOO}'").errorDescriptions == [
            "[ERROR] exec.env-vars.BAR: Env variable 'FOO' \(unavailable)",
            "[ERROR] exec.env-vars.FOO: Env variable 'BAR' \(unavailable)",
        ])
        #expect(parse("[exec.env-vars]\nPWD = ''").errorDescriptions == ["[ERROR] exec.env-vars.PWD: Changing 'PWD' is not allowed"])
        #expect(parse("[exec.env-vars]\nFOO = '${BAR'").errorDescriptions == ["[ERROR] exec.env-vars.FOO: Unbalanced curly braces"])
        #expect(parse("exec.env = {}").errorDescriptions == ["[ERROR] exec.env: Unknown key"])
    }

    @Test func envInterpolationSyntax() throws {
        func expand(_ string: String, _ variables: [String: String] = [:]) -> String? {
            guard case .success(let tokens) = EnvInterpolation.tokens(string) else { return nil }
            return tokens.map { token in
                switch token {
                    case .literal(let literal): literal
                    case .variable(let name): variables[name] ?? "<missing>"
                }
            }.joined()
        }
        #expect(expand("echo ${foo}", ["foo": "bar"]) == "echo bar")
        #expect(expand("echo $foo") == "echo $foo")
        #expect(expand("echo $$foo") == "echo $$foo")
        #expect(expand("echo $${foo}", ["foo": "bar"]) == "echo $bar")
        #expect(expand("echo $") == "echo $")
        #expect(expand("echo ${foo") == nil)
        #expect(expand("echo ${foo{bar}") == nil)
        #expect(expand("echo ${foo$bar}") == nil)
    }

    // MARK: key-mapping

    @Test func keyMapping() {
        let result = parse("""
            [key-mapping.key-notation-to-key-code]
                q = 'q'
                unicorn = 'u'

            [mode.main.binding]
                alt-unicorn = 'workspace wonderland'
            """)
        #expect(result.errors == [])
        #expect(result.config.keyMapping.overrides == ["q": VirtualKey.q, "unicorn": VirtualKey.u])
        let binding = result.config.modes["main"]?.bindings["alt-unicorn"]
        #expect(binding?.chord == KeyChord(modifiers: [.alt], key: "unicorn", keyCode: VirtualKey.u))
        #expect(binding?.chord.normalizedDescriptor == "alt-u")

        #expect(parse("""
            [key-mapping.key-notation-to-key-code]
                q = 'qw'
                ' f' = 'f'
            """).errorDescriptions == [
            "[ERROR] key-mapping.key-notation-to-key-code: ' f' is invalid key notation",
            "[ERROR] key-mapping.key-notation-to-key-code.q: 'qw' is invalid key code",
        ])
        #expect(parse("key-mapping.preset = 'azerty'").errorDescriptions == [
            "[ERROR] key-mapping.preset: Can't parse 'azerty'.\nPossible values: (qwerty|dvorak|colemak)",
        ])
    }

    @Test func dvorakAndColemakPresets() {
        let dvorak = parse("""
            key-mapping.preset = 'dvorak'
            [mode.main.binding]
                alt-quote = 'workspace 1'
                alt-h = 'focus left'
            """)
        #expect(dvorak.errors == [])
        #expect(dvorak.config.keyMapping.preset == .dvorak)
        let bindings = dvorak.config.modes["main"]!.bindings
        #expect(bindings["alt-quote"]?.chord.keyCode == VirtualKey.q)
        #expect(bindings["alt-quote"]?.chord.normalizedDescriptor == "alt-q")
        #expect(bindings["alt-h"]?.chord.keyCode == VirtualKey.j)

        let colemak = parse("key-mapping.preset = 'colemak'")
        #expect(colemak.errors == [])
        #expect(colemak.config.keyMapping.resolve()["f"] == VirtualKey.e)
    }

    @Test func tomlInlineTablesSpanningLines() {
        let result = parse("""
            key-mapping.key-notation-to-key-code = {
                unicorn = 'u',
            }
            """)
        #expect(result.errors == [])
        #expect(result.config.keyMapping.overrides == ["unicorn": VirtualKey.u])
    }
}
