import Foundation
import Testing
@testable import SilkIPC

private let aerospaceCLI = "/opt/homebrew/bin/aerospace"

/// Drives the real brew `aerospace` CLI against a stub Silk server on AeroSpace's socket path.
///
/// Opt-in, because AeroSpace.app must not be running (it owns that path):
///
///     osascript -e 'quit app "AeroSpace"'
///     SILK_LIVE_AEROSPACE_CLI=1 swift test --filter LiveAeroSpaceCLITests
///     open -a AeroSpace
@Suite(
    .enabled(if: ProcessInfo.processInfo.environment["SILK_LIVE_AEROSPACE_CLI"] == "1"),
    .enabled(if: FileManager.default.isExecutableFile(atPath: aerospaceCLI)),
    .timeLimit(.minutes(1)),
    .serialized
)
struct LiveAeroSpaceCLITests {
    private final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [ClientRequest] = []
        func append(_ request: ClientRequest) { lock.withLock { requests.append(request) } }
        var all: [ClientRequest] { lock.withLock { requests } }
    }

    private struct Output: Equatable {
        var stdout: String
        var stderr: String
        var exitCode: Int32
    }

    private func run(_ arguments: [String], executable: String = aerospaceCLI, environment: [String: String] = [:]) throws -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "AEROSPACE_WINDOW_ID")
        env.removeValue(forKey: "AEROSPACE_WORKSPACE")
        env["PATH"] = "/opt/homebrew/bin:/usr/bin:/bin"
        process.environment = env.merging(environment) { $1 }
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        let stderr = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Output(stdout: String(decoding: stdout, as: UTF8.self), stderr: String(decoding: stderr, as: UTF8.self), exitCode: process.terminationStatus)
    }

    /// Answers the three commands `~/.slack-placement.sh` uses, like AeroSpace would on a two-monitor desk.
    private func startStub(_ log: Log) throws -> IPCServer {
        let server = IPCServer(
            endpoints: [.aerospace],
            handlerQueue: DispatchQueue(label: "live-stub"),
            initialEvents: { _ in [.focusChanged(windowId: 123, workspace: "4")] },
            handler: { request, reply in
                log.append(request)
                switch request.args {
                    case ["list-monitors", "--count"]:
                        reply.send(exitCode: 0, stdout: "2")
                    case ["list-windows", "--all", "--format", "%{window-id}|%{app-bundle-id}"]:
                        reply.send(exitCode: 0, stdout: "123|com.tinyspeck.slackmacgap\n456|com.apple.Safari")
                    case ["move-node-to-workspace", "--window-id", "123", "10"]:
                        reply.send(exitCode: 0)
                    case []:
                        reply.send(exitCode: 2, stderr: "Can't parse empty string command")
                    default:
                        reply.send(exitCode: 2, stderr: "simulated failure")
                }
            }
        )
        try server.start()
        return server
    }

    @Test func aerospaceCLIWorksAgainstSilk() throws {
        let log = Log()
        let server = try startStub(log)
        defer { server.stop() }

        #expect(try run(["list-monitors", "--count"]) == Output(stdout: "2\n", stderr: "", exitCode: 0))
        #expect(try run(["list-windows", "--all", "--format", "%{window-id}|%{app-bundle-id}"])
            == Output(stdout: "123|com.tinyspeck.slackmacgap\n456|com.apple.Safari\n", stderr: "", exitCode: 0))
        #expect(try run(["move-node-to-workspace", "--window-id", "123", "10"], environment: ["AEROSPACE_WINDOW_ID": "77", "AEROSPACE_WORKSPACE": "W"])
            == Output(stdout: "", stderr: "", exitCode: 0))
        #expect(log.all.last == ClientRequest(args: ["move-node-to-workspace", "--window-id", "123", "10"], windowId: 77, workspace: "W"))

        // A command failing server-side prints its error and no "client/server versions don't match" warning.
        #expect(try run(["list-workspaces", "--all"]) == Output(stdout: "", stderr: "simulated failure\n", exitCode: 2))

        // `--version` mirrors the client's own version: no mismatch warning.
        let version = try run(["--version"])
        let lines = version.stdout.split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines.first.map { String($0.dropFirst("aerospace CLI client version: ".count)) }
            == lines.last.map { String($0.dropFirst("AeroSpace.app server version: ".count)) })
        #expect(version.stderr == "")
        #expect(version.exitCode == 0)
    }

    @Test func slackPlacementScript() throws {
        let script = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".slack-placement.sh").path
        try #require(FileManager.default.fileExists(atPath: script))
        let log = Log()
        let server = try startStub(log)
        defer { server.stop() }
        #expect(try run([script], executable: "/bin/sh") == Output(stdout: "", stderr: "", exitCode: 0))
        #expect(log.all.map(\.args) == [
            ["list-monitors", "--count"],
            ["list-windows", "--all", "--format", "%{window-id}|%{app-bundle-id}"],
            ["move-node-to-workspace", "--window-id", "123", "10"],
        ])
    }

    @Test func subscribeStreamsJSONLines() async throws {
        let server = try startStub(Log())
        defer { server.stop() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: aerospaceCLI)
        process.arguments = ["subscribe", "focus-changed"]
        let out = Pipe()
        process.standardOutput = out
        try process.run()
        let reader = out.fileHandleForReading
        func line() -> String {
            var data = Data()
            while let byte = try? reader.read(upToCount: 1), !byte.isEmpty, byte != Data("\n".utf8) { data.append(byte) }
            return String(decoding: data, as: UTF8.self)
        }
        #expect(line() == #"{"_event":"focus-changed","windowId":123,"workspace":"4"}"#)
        server.broadcast(.focusChanged(windowId: 456, workspace: "10"))
        #expect(line() == #"{"_event":"focus-changed","windowId":456,"workspace":"10"}"#)
        process.terminate()
        process.waitUntilExit()
        let deadline = Date().addingTimeInterval(5)
        while server.hasSubscribers(for: .focusChanged) && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(!server.hasSubscribers(for: .focusChanged))
    }
}
