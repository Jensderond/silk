/// `exec-and-forget <bash-script>`: only valid as a whole config script, never inside shell syntax.
struct ExecAndForgetCommand: Command {
    static let kind = CommandKind.execAndForget

    var common: CommonArgs
    /// Everything after `exec-and-forget`, verbatim (including the leading space).
    let bashScript: String

    init(bashScript: String) {
        self.common = CommonArgs(rawArgs: [bashScript])
        self.bashScript = bashScript
    }

    var description: String { CommandKind.execAndForget.rawValue + " " + bashScript }

    func run(_ context: CommandContext) -> Int32 {
        ExitCode.from(context.world.execAndForget(bashScript, env: context.env))
    }
}
