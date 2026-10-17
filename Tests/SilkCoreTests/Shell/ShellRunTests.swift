import Testing
@testable import SilkCore

// Ported from AeroSpace's ShellRunTest and EvalCommandTest.

@Suite struct ShellRunTests {
    let t = TestHarness()

    private func focus(_ name: String) {
        #expect(t.world.focusWorkspace(t.workspace(name)))
    }

    @Test func or() {
        focus("a")
        #expect(t.run("true || workspace b").exitCode == 0)
        #expect(t.world.focus.workspace.name == "a")
        #expect(t.run("false || workspace b").exitCode == 0)
        #expect(t.world.focus.workspace.name == "b")
        #expect(t.run("false || false || false").exitCode == 1)
        focus("a")
        #expect(t.run("false || workspace b || workspace c").exitCode == 0)
        #expect(t.world.focus.workspace.name == "b")
    }

    @Test func and() {
        focus("a")
        #expect(t.run("false && workspace b").exitCode == 1)
        #expect(t.world.focus.workspace.name == "a")
        #expect(t.run("true && workspace b").exitCode == 0)
        #expect(t.world.focus.workspace.name == "b")
        focus("a")
        #expect(t.run("workspace b && false && workspace c").exitCode == 1)
        #expect(t.world.focus.workspace.name == "b")
        #expect(t.run("true && true && true").exitCode == 0)
    }

    @Test func seq() {
        focus("a")
        #expect(t.run("false; workspace b").exitCode == 0)
        #expect(t.world.focus.workspace.name == "b")
        #expect(t.run("true; false").exitCode == 1)
        #expect(t.run("false; true").exitCode == 0)
        #expect(t.run("echo -- foo; echo -- bar; echo -- baz") == CommandResult(exitCode: 0, stdout: "foo\nbar\nbaz"))
    }

    @Test func pipe() {
        focus("a")
        #expect(t.run("echo -- a b c | workspace --stdin next").exitCode == 0)
        #expect(t.world.focus.workspace.name == "b")
        #expect(t.run("echo -- foo | echo -- bar") == CommandResult(exitCode: 0, stdout: "bar"))
        #expect(t.run("echo --stderr -- err1 | echo -- out2") == CommandResult(exitCode: 0, stdout: "out2", stderr: "err1"))
        #expect(t.run("false | true").exitCode == 1)
        #expect(t.run("true | false").exitCode == 1)
        #expect(t.run("true | true").exitCode == 0)
    }

    @Test func pipeForwardsOriginalStdin() {
        focus("a")
        let result = t.run(args: ["eval", "--stdin", "workspace --stdin next | echo -- done"], stdin: "a\nb\nc\n")
        #expect(result == CommandResult(exitCode: 0, stdout: "done"))
        #expect(t.world.focus.workspace.name == "b")
    }

    @Test func parseErrorsOfScripts() {
        #expect(t.run("workspace") == CommandResult(exitCode: 2, stderr: "ERROR: Argument '(<workspace-name>|next|prev)' is mandatory"))
        #expect(t.run("foo") == CommandResult(exitCode: 2, stderr: "Unrecognized subcommand 'foo'"))
        #expect(t.run("echo 'a") == CommandResult(exitCode: 2, stderr: "Line 1 Column 8: Last quote ' isn't closed."))
        #expect(t.run("") == CommandResult(exitCode: 0))
        #expect(t.run("eval 'true'") == CommandResult(exitCode: 2, stderr: "Illegal eval (Tip: nested evals are forbidden)"))
    }

    @Test func execAndForgetTakesTheWholeScript() {
        let parsed = parseSingle("exec-and-forget echo 'foo'", as: ExecAndForgetCommand.self)
        #expect(parsed?.bashScript == " echo 'foo'")
        #expect(parsed?.description == "exec-and-forget  echo 'foo'")
        t.run("exec-and-forget open -n /Applications/Ghostty.app; mode main")
        #expect(t.platform.execScripts == [" open -n /Applications/Ghostty.app; mode main"])
        #expect(t.run(args: ["exec-and-forget", "true"]) == CommandResult(exitCode: 2, stderr: "Unrecognized subcommand 'exec-and-forget'"))
        #expect(t.run(args: ["eval", "exec-and-forget true"]) == CommandResult(exitCode: 2, stderr: "Unrecognized subcommand 'exec-and-forget'"))
    }

    @Test func trueAndFalse() {
        #expect(parseScript("true foo").errorOrNil == "ERROR: Unknown argument 'foo'")
        #expect(parseScript("false foo").errorOrNil == "ERROR: Unknown argument 'foo'")
        #expect(parseScript("true -h").isHelp)
        #expect(parseScript("false --help").isHelp)
        #expect(t.run("true").exitCode == 0)
        #expect(t.run("false").exitCode == 1)
    }
}

@Suite struct EvalCommandTests {
    let t = TestHarness()

    @Test func parse() {
        #expect(parseSingle("eval 'workspace foo'", as: EvalCommand.self)?.shellExpr == "workspace foo")
        #expect(parseScript("eval").errorOrNil == "ERROR: Argument '<aerospace-shell-expr>' is mandatory")
        #expect(parseSingle("eval -- '--anything'", as: EvalCommand.self)?.shellExpr == "--anything")
        #expect(parseScript("eval --").errorOrNil == "ERROR: Argument '<aerospace-shell-expr>' is mandatory")
    }

    @Test func run() {
        t.world.focusWorkspace(t.workspace("a"))
        #expect(t.run(args: ["eval", "workspace b"]) == CommandResult(exitCode: 0))
        #expect(t.world.focus.workspace.name == "b")
        #expect(t.run(args: ["eval", "echo -- hello"]) == CommandResult(exitCode: 0, stdout: "hello"))
        t.world.focusWorkspace(t.workspace("a"))
        #expect(t.run(args: ["eval", "workspace a && workspace b"]).exitCode == 0)
        #expect(t.world.focus.workspace.name == "b")
        #expect(t.run(args: ["eval", ""]) == CommandResult(exitCode: 0))
        #expect(t.run(args: ["eval", "no-such-command"]) == CommandResult(exitCode: 2, stderr: "Unrecognized subcommand 'no-such-command'"))
        #expect(t.run(args: ["eval", "workspace"]) == CommandResult(exitCode: 2, stderr: "ERROR: Argument '(<workspace-name>|next|prev)' is mandatory"))
        #expect(t.run(args: ["eval", "workspace --help"]) == CommandResult(exitCode: 2, stderr: "--help is not supported inside eval command"))
        t.world.focusWorkspace(t.workspace("a"))
        #expect(t.run(args: ["eval", "eval \"workspace b\""]) == CommandResult(exitCode: 2, stderr: "Illegal eval (Tip: nested evals are forbidden)"))
        #expect(t.world.focus.workspace.name == "a")
    }
}
