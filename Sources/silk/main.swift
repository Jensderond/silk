// `silk`: argv-compatible replacement for the `aerospace` CLI (AeroSpace 0.21 `Sources/Cli/_main.swift`).
//
// Commands are parsed and validated by the server; the client only does what AeroSpace's client does before
// connecting: top-level `--help`/`--version`, the local `true`/`false` shortcuts, deciding whether to forward
// stdin, and streaming `subscribe` output.

import Darwin
import Foundation
import SilkIPC

let failExitCode = WireProtocol.failureExitCode
let notRunningMessage = "Silk isn't running. Start it with `open -a Silk`"

func eprint(_ message: String) {
    fputs(message + "\n", stderr)
}

func exit(_ code: Int32, out: String? = nil, err: String? = nil) -> Never {
    if let out { print(out) }
    if let err { eprint(err) }
    exit(code)
}

func connect() -> IPCClient {
    do {
        return try IPCClient(path: IPCEndpoint.silkSocketPath)
    } catch .serverNotRunning {
        exit(failExitCode, err: notRunningMessage)
    } catch {
        exit(failExitCode, err: "Can't connect to Silk: \(error)")
    }
}

/// `silk --version`: both versions, plus a warning when the CLI belongs to a different install than the server.
func printVersion() -> Never {
    let serverVersion: String?
    do {
        let client = try IPCClient(path: IPCEndpoint.silkSocketPath)
        serverVersion = try client.send(ClientRequest(args: [])).serverVersionAndHash
    } catch .serverNotRunning {
        eprint(notRunningMessage)
        serverVersion = nil
    } catch .protocolVersionMismatch(let server) {
        exit(failExitCode, err: IPCClientError.protocolVersionMismatch(server: server).description)
    } catch {
        eprint("\(error)")
        serverVersion = nil
    }
    print(
        """
        silk CLI client version: \(SilkVersion.current)
        Silk.app server version: \(serverVersion ?? "Unknown. The server is not responding")
        """
    )
    if let serverVersion, serverVersion != SilkVersion.current {
        eprint(
            """
            Warning: Silk client/server versions don't match. Possible fixes:
              - Restart Silk.app (server restart is required after each update)
              - Reinstall and restart Silk (corrupted installation)
            """
        )
    }
    exit(0)
}

enum StdinDisposition {
    case forward
    case ignore
    /// AeroSpace ≥ 0.20 rejects piped stdin that `workspace`/`move-node-to-workspace` with `next|prev`
    /// would have consumed implicitly in older versions.
    case implicitForbidden
}

/// Mirrors AeroSpace's client-side stdin decision without a full argument parser: `--stdin` (before `--`)
/// forwards stdin; `workspace`/`move-node-to-workspace` with a `next|prev` target, neither `--stdin` nor
/// `--no-stdin`, and a non-TTY stdin is the "implicit stdin" error. Conflicting flags are left to the server.
func stdinDisposition(_ args: [String]) -> StdinDisposition {
    let options = args.dropFirst().prefix { $0 != "--" }
    let explicit = options.contains("--stdin")
    let explicitOff = options.contains("--no-stdin")
    if explicit && !explicitOff { return .forward }
    guard !explicit && !explicitOff, ["workspace", "move-node-to-workspace"].contains(args[0]), isatty(STDIN_FILENO) != 1
    else { return .ignore }
    var skipValue = false
    for token in options {
        if skipValue {
            skipValue = false
        } else if token == "--window-id" {
            skipValue = true
        } else if !token.hasPrefix("-") {
            return token == "next" || token == "prev" ? .implicitForbidden : .ignore
        }
    }
    return .ignore
}

/// At most 1000 lines, like AeroSpace.
func readStdin() -> String {
    var stdin = ""
    var lines = 0
    while let line = readLine(strippingNewline: false) {
        stdin += line
        lines += 1
        if lines > 1000 {
            exit(failExitCode, err: "stdin number of lines limit is exceeded")
        }
    }
    return stdin
}

/// Prints events as JSON lines until the server goes away. A `ServerAnswer` instead of events means the
/// server rejected the arguments (or printed help): print it like a regular command.
func runSubscribe(_ client: IPCClient, _ request: ClientRequest) -> Never {
    do {
        try client.write(request)
        while true {
            let frame = try client.readFrame()
            if let answer = try? JSONDecoder().decode(ServerAnswer.self, from: frame) {
                finish(with: answer)
            }
            print(String(decoding: frame, as: UTF8.self))
            fflush(stdout)
        }
    } catch .connectionClosed {
        exit(failExitCode, err: "Silk closed the subscription")
    } catch {
        exit(failExitCode, err: "subscribe error: \(error)")
    }
}

func finish(with answer: ServerAnswer) -> Never {
    if !answer.stdout.isEmpty { print(answer.stdout) }
    if !answer.stderr.isEmpty { eprint(answer.stderr) }
    if answer.exitCode != 0 && answer.serverVersionAndHash != SilkVersion.current {
        eprint(
            """
            Warning: Silk client/server versions don't match
              - silk CLI client version: \(SilkVersion.current)
              - Silk.app server version: \(answer.serverVersionAndHash)
              Possible fixes:
              - Restart Silk.app (server restart is required after each update)
              - Reinstall and restart Silk (corrupted installation)
            """
        )
    }
    exit(answer.exitCode)
}

// MARK: - Entry point

let args = Array(CommandLine.arguments.dropFirst())
let programName = CommandLine.arguments.first ?? "silk"

if args.isEmpty {
    exit(failExitCode, err: usage(programName: programName))
}
switch args[0] {
    case "--help", "-h": exit(0, out: usage(programName: programName))
    case "--version", "-v": printVersion()
    default: break
}
if args == ["true"] { exit(0) }
if args == ["false"] { exit(1) }

var stdin = ""
switch stdinDisposition(args) {
    case .forward: stdin = readStdin()
    case .ignore: break
    case .implicitForbidden:
        exit(
            failExitCode,
            err: """
                ERROR: Implicit stdin is detected (stdin is not TTY). Implicit stdin was forbidden in AeroSpace v0.20.0.
                1. Please supply '--stdin' flag to make stdin explicit and preserve old AeroSpace behavior
                2. You can also use '--no-stdin' flag to behave as if no stdin was supplied
                Breaking change issue: https://github.com/nikitabobko/AeroSpace/issues/1683
                """
        )
}

let environment = ProcessInfo.processInfo.environment
let request = ClientRequest(
    args: args,
    stdin: stdin,
    windowId: environment["AEROSPACE_WINDOW_ID"].flatMap(UInt32.init),
    workspace: environment["AEROSPACE_WORKSPACE"]
)
let client = connect()
if args[0] == "subscribe" {
    runSubscribe(client, request)
}
do {
    finish(with: try client.send(request))
} catch {
    exit(failExitCode, err: "\(error)")
}
