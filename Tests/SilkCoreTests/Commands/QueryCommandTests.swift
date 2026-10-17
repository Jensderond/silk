import Foundation
import SilkConfig
import Testing
@testable import SilkCore

func binding(_ descriptor: String, _ scripts: String...) -> Binding {
    let chord = KeyNotation.parseChord(descriptor, mapping: KeyMapping())
    guard case .success(let parsed) = chord else { preconditionFailure("Bad chord \(descriptor)") }
    return Binding(descriptor: descriptor, chord: parsed, commands: CommandScripts(scripts))
}

func mode(_ name: String, _ bindings: Binding...) -> Mode {
    Mode(name: name, bindings: Dictionary(uniqueKeysWithValues: bindings.map { ($0.descriptor, $0) }))
}

private let allFormatVars = "(window-id|window-is-fullscreen|window-title|window-layout|window-parent-container-layout|workspace|workspace-is-focused|workspace-is-visible|workspace-root-container-layout|app-bundle-id|app-name|app-pid|app-exec-path|app-bundle-path|monitor-id|monitor-appkit-nsscreen-screens-id|monitor-name|monitor-is-main)"

@Suite struct TestCommandTests {
    let t = TestHarness()

    @Test func parse() {
        let test = parseSingle("test %{app-bundle-id} = foo", as: TestCommand.self)
        #expect(test?.lhs == .app(.appBundleId))
        #expect(test?.infixOperator == .equals)
        #expect(test?.rhs == "foo")
        #expect(parseSingle("test-not %{app-bundle-id} ~= foo", as: TestNotCommand.self)?.test.infixOperator == .matchesRegex)
        #expect(parseScript("test %{foo} = foo").errorOrNil == "ERROR: Can't parse 'foo'.\n       Possible values: \(allFormatVars)")
        #expect(parseScript("test foo = foo").errorOrNil == "ERROR: Left hand side must be a single interpolation variable")
        #expect(parseScript("test foo%{app-bundle-id} = foo").errorOrNil == "ERROR: Left hand side must be a single interpolation variable")
        #expect(parseScript("test").errorOrNil == "ERROR: Argument '<lhs>' is mandatory\nERROR: Argument '<operator>' is mandatory\nERROR: Argument '<rhs>' is mandatory")
        #expect(parseScript("test foo = %{app-bundle-id}").errorOrNil == "ERROR: Left hand side must be a single interpolation variable\nERROR: Right hand side doesn't allow interpolation variables")
        #expect(parseScript("test %{app-bundle-id} = %{app-bundle-id}").errorOrNil == "ERROR: Right hand side doesn't allow interpolation variables")
        #expect(parseScript("test %{newline} = foo").errorOrNil == "ERROR: Can't parse 'newline'.\n       Possible values: \(allFormatVars)")
        #expect(parseScript("test %{window-id} = %{invalid}").errorOrNil == "ERROR: Right hand side doesn't allow interpolation variables")
    }

    @Test func exec() {
        #expect(t.focus(t.window(1, in: t.workspace("a").rootTilingContainer)))
        #expect(t.run("test %{window-id} = 1") == CommandResult(exitCode: 0))
        #expect(t.run("test %{window-id} = 2") == CommandResult(exitCode: 1))
        #expect(t.run("test %{workspace-is-focused} = foo") == CommandResult(exitCode: 2, stderr: "Can't convert String 'foo' to Bool"))
        #expect(t.run("test %{workspace-is-focused} ~= foo") == CommandResult(exitCode: 2, stderr: "Interpolation variable: 'workspace-is-focused' has a type of Bool. The Bool type is not compatible with '~=' operator."))
        #expect(t.run("test %{workspace-is-focused} = true") == CommandResult(exitCode: 0))
        #expect(t.run("test %{workspace-is-focused} = false") == CommandResult(exitCode: 1))
        #expect(t.run("test %{window-id} = abc") == CommandResult(exitCode: 2, stderr: "Can't convert String 'abc' to Int"))
        #expect(t.run("test %{window-id} ~= 1") == CommandResult(exitCode: 2, stderr: "Interpolation variable: 'window-id' has a type of Int. The Int type is not compatible with '~=' operator."))
        #expect(t.run("test %{app-bundle-id} = bobko.AeroSpace.test-app") == CommandResult(exitCode: 0))
        #expect(t.run("test %{app-bundle-id} = other.bundle.id") == CommandResult(exitCode: 1))
        #expect(t.run("test %{app-bundle-id} ~= AERO") == CommandResult(exitCode: 0))
        #expect(t.run("test %{app-bundle-id} ~= zzzzz") == CommandResult(exitCode: 1))
        let invalidRegex = t.run("test %{app-bundle-id} ~= [")
        #expect(invalidRegex.exitCode == 2)
        #expect(invalidRegex.stderr.contains("Can't parse '[' regex"))
        #expect(t.run("test-not %{window-id} = 1") == CommandResult(exitCode: 1))
        #expect(t.run("test-not %{window-id} = 2") == CommandResult(exitCode: 0))
        #expect(t.run("test-not %{workspace-is-focused} = foo") == CommandResult(exitCode: 2, stderr: "Can't convert String 'foo' to Bool"))
    }

    @Test func execWithoutWindow() {
        t.world.focusWorkspace(t.workspace("a"))
        #expect(t.run("test %{window-id} = 1") == CommandResult(exitCode: 2, stderr: "No window is focused"))
        #expect(t.run("test %{workspace-is-focused} = true") == CommandResult(exitCode: 0))
        #expect(t.run(args: ["test", "%{window-id}", "=", "1"], env: CommandEnv(windowId: 9999))
            == CommandResult(exitCode: 2, stderr: "Invalid <window-id> 9999 specified in AEROSPACE_WINDOW_ID env variable"))
    }
}

@Suite struct EchoCommandTests {
    let t = TestHarness()

    @Test func parse() {
        #expect(parseSingle("echo -- foo bar", as: EchoCommand.self)?.args == [[.literal("foo")], [.literal("bar")]])
        #expect(parseSingle("echo --stderr -- foo", as: EchoCommand.self)?.isStderr == true)
        #expect(parseSingle("echo -- 'id: %{window-id}'", as: EchoCommand.self)?.args == [[.literal("id: "), .interVar(.formatVar(.window(.windowId)))]])
        #expect(parseSingle("echo -- --stderr", as: EchoCommand.self)?.args == [[.literal("--stderr")]])
        #expect(parseSingle("echo -- -h", as: EchoCommand.self)?.args == [[.literal("-h")]])
        #expect(parseScript("echo").errorOrNil == "ERROR: Argument '--' is mandatory\nERROR: Argument '<string>' is mandatory")
        #expect(parseScript("echo --").errorOrNil == "ERROR: Argument '<string>' is mandatory")
        #expect(parseScript("echo foo").errorOrNil == "ERROR: Expected: --. Got: 'foo'")
        #expect(parseScript("echo --stderr foo").errorOrNil == "ERROR: Expected: --. Got: 'foo'")
        #expect(parseScript("echo -- %{foo}").errorOrNil == "ERROR: Can't parse 'foo'.\n       Possible values: (window-id|window-is-fullscreen|window-title|window-layout|window-parent-container-layout|workspace|workspace-is-focused|workspace-is-visible|workspace-root-container-layout|app-bundle-id|app-name|app-pid|app-exec-path|app-bundle-path|monitor-id|monitor-appkit-nsscreen-screens-id|monitor-name|monitor-is-main|right-padding|newline|tab)")
        #expect(parseScript("echo -h").isHelp)
    }

    @Test func run() {
        t.world.focusWorkspace(t.workspace("ws"))
        #expect(t.run("echo -- foo bar baz") == CommandResult(exitCode: 0, stdout: "foo\nbar\nbaz"))
        #expect(t.run("echo --stderr -- foo") == CommandResult(exitCode: 0, stderr: "foo"))
        #expect(t.run("echo -- '%{window-id}'") == CommandResult(exitCode: 2, stderr: noWindowIsFocused))
        #expect(t.run("echo -- '%{workspace}'") == CommandResult(exitCode: 0, stdout: "ws"))
        t.focus(t.window(42, in: t.workspace("ws").rootTilingContainer))
        #expect(t.run("echo -- 'id: %{window-id}'") == CommandResult(exitCode: 0, stdout: "id: 42"))
        #expect(t.run("echo --stderr -- '%{window-id}'") == CommandResult(exitCode: 0, stderr: "42"))
    }
}

@Suite struct ConfigCommandTests {
    @Test func parse() {
        #expect(parseScript("config --major-keys").errorOrNil == nil)
        #expect(parseScript("config --get foo --keys --json").errorOrNil == nil)
        #expect(parseScript("config").errorOrNil == "Mandatory flag is not specified (--get|--major-keys|--all-keys|--config-path)")
        #expect(parseScript("config --keys").errorOrNil == "Mandatory flag is not specified (--get|--major-keys|--all-keys|--config-path)")
        #expect(parseScript("config --major-keys --keys").errorOrNil == "--keys flag requires --get flag")
        #expect(parseScript("config --major-keys --json").errorOrNil == "--json flag requires --get flag")
        let conflict = parseScript("config --major-keys --all-keys").errorOrNil
        #expect(conflict?.hasPrefix("Conflicting flags are specified:") == true)
    }

    @Test func configPath() {
        let platform = FakePlatform()
        let manager = WindowManager(config: testConfig(), configURL: URL(fileURLWithPath: "/Users/test/.aerospace.toml"), platform: platform, monitors: [testMonitor])
        #expect(manager.run(args: ["config", "--config-path"]) == CommandResult(exitCode: 0, stdout: "/Users/test/.aerospace.toml"))
    }

    @Test func keys() {
        let t = TestHarness(config: testConfig {
            $0.modes = ["main": mode("main", binding("alt-h", "focus left")), "service": mode("service", binding("esc", "reload-config", "mode main"))]
        })
        #expect(t.run("config --major-keys").stdout == ".\nmode\nmode.main.binding\nmode.service.binding")
        #expect(t.run("config --all-keys").stdout == ".\nmode\nmode.main\nmode.main.binding\nmode.main.binding.alt-h\nmode.service\nmode.service.binding\nmode.service.binding.esc")
        #expect(t.run("config --get mode.main.binding.alt-h") == CommandResult(exitCode: 0, stdout: "focus left"))
        #expect(t.run("config --get mode.service.binding.esc").stdout == "reload-config; mode main")
        #expect(t.run("config --get mode --keys").stdout == "main\nservice")
        #expect(t.run("config --get . --keys").stdout == "mode")
        #expect(t.run("config --get . --keys --json").stdout == JSONEncoder.aeroSpace.encodeToString(["mode"]))
        #expect(t.run("config --get mode.main.binding --json").stdout == JSONEncoder.aeroSpace.encodeToString(["alt-h": "focus left"]))
        #expect(t.run("config --get .") == CommandResult(exitCode: 2, stderr: "Complicated objects can be printed only with --json flag. Alternatively, you can try to inspect keys of the object with --keys flag"))
        #expect(t.run("config --get mode.main.binding.alt-h --keys") == CommandResult(exitCode: 2, stderr: "--keys flag cannot be applied to scalar object 'string(\"focus left\")'"))
        #expect(t.run("config --get mode.main.binding.alt-h.foo") == CommandResult(exitCode: 2, stderr: "Can't dereference scalar value 'focus left'"))
        #expect(t.run("config --get nonExistent") == CommandResult(exitCode: 2, stderr: "No value at key token 'nonExistent'"))
        #expect(t.run(args: ["config", "--get", ""]) == CommandResult(exitCode: 2, stderr: "Invalid empty key"))
        #expect(t.run("config --get a..b") == CommandResult(exitCode: 2, stderr: "Invalid key 'a..b'"))
        #expect(t.run("config --get a.") == CommandResult(exitCode: 2, stderr: "Invalid key 'a.'"))
    }

    @Test func execAndForgetBindingDescriptionKeepsAeroSpacesDoubleSpace() {
        let t = TestHarness(config: testConfig { $0.modes = ["main": mode("main", binding("alt-enter", "exec-and-forget open -n /Applications/Ghostty.app"))] })
        #expect(t.run("config --get mode.main.binding.alt-enter").stdout == "exec-and-forget  open -n /Applications/Ghostty.app")
    }

    @Test func arrays() {
        let array = ConfigMapValue.array([.scalar(.string("a")), .map(["k": .scalar(.int(1))])])
        guard case .success(.scalar(.string(let value))) = ConfigMapValue.array([.scalar(.string("a")), .scalar(.string("b"))]).find(["1"]) else {
            Issue.record("Expected b")
            return
        }
        #expect(value == "b")
        if case .failure(let error) = array.find(["5"]) { #expect(error.message == "Index out of bounds. Index: 5, Size: 2") }
        if case .failure(let error) = array.find(["foo"]) { #expect(error.message == "Can't convert key token 'foo' to Int") }
        var keys: [String] = []
        array.dumpAllKeys(path: ".", into: &keys)
        #expect(keys == [".", "0", "1", "1.k"])
    }
}
