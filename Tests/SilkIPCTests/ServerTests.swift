import Darwin
import Foundation
import Testing
@testable import SilkIPC

/// A unique socket path in the (short enough) per-user temporary directory.
private func temporarySocketPath() -> String {
    NSTemporaryDirectory() + "silk-\(UUID().uuidString.prefix(8)).sock"
}

/// Runs blocking socket code off the cooperative thread pool.
private func onThread<T>(_ body: @escaping () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        Thread { continuation.resume(with: Result { try body() }) }.start()
    }
}

private func eventually(timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return condition()
}

private final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: T
    init(_ value: T) { storage = value }
    var value: T {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}

private let version = "9.9.9-test cafebabe"

/// A started server on a fresh path; replies `echo:<args>` (plus env context) unless given another handler.
private func makeServer(
    path: String = temporarySocketPath(),
    versionReporting: IPCEndpoint.VersionReporting = .fixed(version),
    initialEvents: @escaping IPCServer.InitialEventsProvider = { _ in [] },
    onEndpointLost: ((IPCEndpoint) -> Void)? = nil,
    handler: IPCServer.Handler? = nil
) throws -> (IPCServer, String) {
    let server = IPCServer(
        endpoints: [IPCEndpoint(path: path, versionReporting: versionReporting)],
        handlerQueue: DispatchQueue(label: "silk.ipc.tests.handler"),
        initialEvents: initialEvents,
        onEndpointLost: onEndpointLost,
        handler: handler ?? { request, reply in
            reply.send(exitCode: 0, stdout: "echo:" + request.args.joined(separator: " "), stderr: "\(request.windowId.map(String.init) ?? "-") \(request.workspace ?? "-") \(request.stdin)")
        }
    )
    try server.start()
    return (server, path)
}

@Suite(.timeLimit(.minutes(1))) struct ServerTests {
    @Test func oneShotRequestsShareAConnection() async throws {
        let (server, path) = try makeServer()
        defer { server.stop() }
        let answers = try await onThread {
            let client = try IPCClient(path: path)
            return try [
                client.send(ClientRequest(args: ["list-monitors", "--count"])),
                client.send(ClientRequest(args: ["workspace", "--stdin", "next"], stdin: "a\nb\n", windowId: 7, workspace: "W")),
            ]
        }
        #expect(answers[0] == ServerAnswer(exitCode: 0, stdout: "echo:list-monitors --count", stderr: "- - ", serverVersionAndHash: version))
        #expect(answers[1] == ServerAnswer(exitCode: 0, stdout: "echo:workspace --stdin next", stderr: "7 W a\nb\n", serverVersionAndHash: version))
    }

    @Test func connectionsAreServedConcurrently() async throws {
        // Every reply is delayed and sent from another queue; 32 clients must not serialize on each other.
        let replyQueue = DispatchQueue(label: "replies", attributes: .concurrent)
        let (server, path) = try makeServer(handler: { request, reply in
            replyQueue.asyncAfter(deadline: .now() + 0.2) { reply.send(exitCode: 3, stdout: request.args[0]) }
        })
        defer { server.stop() }
        let started = Date()
        let results = try await withThrowingTaskGroup(of: (String, ServerAnswer).self) { group in
            for i in 0 ..< 32 {
                group.addTask {
                    try await onThread { ("n\(i)", try IPCClient(path: path).send(ClientRequest(args: ["n\(i)"]))) }
                }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        #expect(Date().timeIntervalSince(started) < 3)
        #expect(results.count == 32)
        for (expected, answer) in results {
            #expect(answer.stdout == expected)
            #expect(answer.exitCode == 3)
        }
    }

    @Test func droppedReplyStillAnswers() async throws {
        let (server, path) = try makeServer(handler: { _, _ in })
        defer { server.stop() }
        let answer = try await onThread { try IPCClient(path: path).send(ClientRequest(args: ["focus", "left"])) }
        #expect(answer.exitCode == 2)
        #expect(answer.stderr.contains("internal error"))
    }

    @Test func firstReplyWins() async throws {
        let (server, path) = try makeServer(handler: { _, reply in
            reply.send(exitCode: 0, stdout: "first")
            reply.send(exitCode: 1, stdout: "second")
        })
        defer { server.stop() }
        let answers = try await onThread {
            let client = try IPCClient(path: path)
            return try [client.send(ClientRequest(args: ["a"])), client.send(ClientRequest(args: ["b"]))]
        }
        #expect(answers.map(\.stdout) == ["first", "first"])
    }

    @Test func malformedRequestIsReportedAndConnectionSurvives() async throws {
        let (server, path) = try makeServer()
        defer { server.stop() }
        let (error, next) = try await onThread {
            let socket = try UnixSocket.make()
            try socket.connect(to: path)
            try socket.writeAll(WireProtocol.encodeUInt32(1))
            _ = try socket.readUInt32()
            try socket.writeFrame(Data("not json".utf8))
            let error = try JSONDecoder().decode(ServerAnswer.self, from: socket.readFrame(maxPayload: 1 << 20))
            try socket.writeFrame(WireProtocol.makeMessageEncoder().encode(ClientRequest(args: ["ok"])))
            let next = try JSONDecoder().decode(ServerAnswer.self, from: socket.readFrame(maxPayload: 1 << 20))
            return (error, next)
        }
        #expect(error.exitCode == 2)
        #expect(error.stderr.hasPrefix("Can't parse request 'not json'.\nError: "))
        #expect(error.serverVersionAndHash == version)
        #expect(next.stdout == "echo:ok")
    }

    @Test func unsupportedProtocolVersionGetsServerVersionThenDisconnect() async throws {
        let (server, path) = try makeServer()
        defer { server.stop() }
        let (serverVersion, closed) = try await onThread {
            let socket = try UnixSocket.make()
            try socket.connect(to: path)
            try socket.writeAll(WireProtocol.encodeUInt32(2))
            let serverVersion = try socket.readUInt32()
            let closed: Bool
            do { _ = try socket.readExactly(1); closed = false } catch { closed = true }
            return (serverVersion, closed)
        }
        #expect(serverVersion == 1)
        #expect(closed)
    }

    @Test func mirroringFallsBackForNonAeroSpaceClients() async throws {
        let (server, path) = try makeServer(versionReporting: .mirrorAeroSpaceClient(fallback: AeroSpaceCompat.targetVersionAndHash))
        defer { server.stop() }
        let answer = try await onThread { try IPCClient(path: path).send(ClientRequest(args: [])) }
        #expect(answer.serverVersionAndHash == AeroSpaceCompat.targetVersionAndHash)
    }

    @Test func clientReportsMissingServer() throws {
        #expect(throws: IPCClientError.serverNotRunning(path: "/tmp/silk-does-not-exist.sock")) {
            try IPCClient(path: "/tmp/silk-does-not-exist.sock")
        }
    }
}

@Suite(.timeLimit(.minutes(1))) struct SocketFileTests {
    @Test func socketFileIsPrivateAndRemovedOnStop() throws {
        let (server, path) = try makeServer()
        var info = stat()
        #expect(lstat(path, &info) == 0)
        #expect(info.st_mode & S_IFMT == S_IFSOCK)
        #expect(info.st_mode & 0o777 == 0o600)
        #expect(throws: IPCServerError.alreadyStarted) { try server.start() }
        server.stop()
        #expect(!FileManager.default.fileExists(atPath: path))
        server.stop()
    }

    @Test func staleSocketFileIsReplaced() async throws {
        let path = temporarySocketPath()
        let stale = try UnixSocket.make()
        try stale.bind(to: path)
        stale.close() // File stays, nobody listens.
        #expect(FileManager.default.fileExists(atPath: path))
        let (server, _) = try makeServer(path: path)
        defer { server.stop() }
        let answer = try await onThread { try IPCClient(path: path).send(ClientRequest(args: ["x"])) }
        #expect(answer.stdout == "echo:x")
    }

    @Test func liveServerIsNotStolen() throws {
        let (first, path) = try makeServer()
        defer { first.stop() }
        let second = IPCServer(endpoints: [.init(path: path, versionReporting: .fixed("other"))], initialEvents: { _ in [] }) { _, _ in }
        #expect(throws: IPCServerError.endpointInUse(.init(path: path, versionReporting: .fixed("other")))) { try second.start() }
        second.stop()
        #expect(FileManager.default.fileExists(atPath: path), "a refused start must not remove the live server's socket")
    }

    @Test func failedStartReleasesEarlierEndpoints() throws {
        let (live, livePath) = try makeServer()
        defer { live.stop() }
        let freePath = temporarySocketPath()
        let server = IPCServer(
            endpoints: [.init(path: freePath, versionReporting: .fixed("")), .init(path: livePath, versionReporting: .fixed(""))],
            initialEvents: { _ in [] }
        ) { _, _ in }
        #expect(throws: IPCServerError.self) { try server.start() }
        #expect(!FileManager.default.fileExists(atPath: freePath))
    }

    @Test func regularFileIsLeftAlone() throws {
        let path = temporarySocketPath()
        try Data("keep".utf8).write(to: URL(fileURLWithPath: path))
        defer { unlink(path) }
        let server = IPCServer(endpoints: [.init(path: path, versionReporting: .fixed(""))], initialEvents: { _ in [] }) { _, _ in }
        #expect(throws: IPCServerError.notASocket(path: path)) { try server.start() }
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "keep")
    }

    @Test func tooLongPathIsRejected() throws {
        let path = "/tmp/" + String(repeating: "x", count: 120) + ".sock"
        let server = IPCServer(endpoints: [.init(path: path, versionReporting: .fixed(""))], initialEvents: { _ in [] }) { _, _ in }
        #expect(throws: IPCServerError.pathTooLong(path: path)) { try server.start() }
    }

    @Test func removedSocketFileIsRecreated() async throws {
        let (server, path) = try makeServer()
        defer { server.stop() }
        server.watchdogInterval = 0.05
        unlink(path)
        #expect(await eventually { FileManager.default.fileExists(atPath: path) })
        let answer = try await onThread { try IPCClient(path: path).send(ClientRequest(args: ["back"])) }
        #expect(answer.stdout == "echo:back")
    }

    @Test func replacedSocketFileReportsLostEndpoint() async throws {
        let lost = Box<[String]>([])
        let (server, path) = try makeServer(onEndpointLost: { lost.value.append($0.path) })
        server.watchdogInterval = 0.05
        // What AeroSpace does on launch: delete the file and bind its own listener.
        unlink(path)
        let usurper = try UnixSocket.make()
        try usurper.bind(to: path)
        try usurper.listen(backlog: 1)
        #expect(await eventually { lost.value == [path] })
        #expect(server.activeEndpoints.isEmpty)
        server.stop()
        #expect(FileManager.default.fileExists(atPath: path), "stop() must not delete a socket file it no longer owns")
        usurper.close()
        unlink(path)
    }
}

@Suite(.timeLimit(.minutes(1))) struct SubscribeTests {
    /// Opens a subscription and returns the client plus a reader yielding decoded frames.
    private func subscribe(_ path: String, _ args: [String]) throws -> IPCClient {
        let client = try IPCClient(path: path)
        try client.write(ClientRequest(args: ["subscribe"] + args))
        return client
    }

    private func readEvent(_ client: IPCClient) throws -> String {
        String(decoding: try client.readFrame(), as: UTF8.self)
    }

    @Test func initialEventsThenBroadcastsFilteredByKind() async throws {
        let requested = Box<Set<ServerEventType>>([])
        let (server, path) = try makeServer(initialEvents: { kinds in
            requested.value = kinds
            return [.focusChanged(windowId: 1, workspace: "A"), .modeChanged(mode: "main")]
        })
        defer { server.stop() }
        let client = try await onThread { try self.subscribe(path, ["focus-changed", "mode-changed"]) }
        let initial = try await onThread { try [self.readEvent(client), self.readEvent(client)] }
        #expect(initial == [#"{"_event":"focus-changed","windowId":1,"workspace":"A"}"#, #"{"_event":"mode-changed","mode":"main"}"#])
        #expect(requested.value == [.focusChanged, .modeChanged])
        #expect(server.hasSubscribers(for: .modeChanged))
        #expect(!server.hasSubscribers(for: .windowDetected))

        server.broadcast(.workspaceChanged(workspace: "B", prevWorkspace: "A")) // not subscribed
        server.broadcast(.focusChanged(windowId: nil, workspace: "B"))
        server.broadcast(.modeChanged(mode: "service"))
        let streamed = try await onThread { try [self.readEvent(client), self.readEvent(client)] }
        #expect(streamed == [#"{"_event":"focus-changed","workspace":"B"}"#, #"{"_event":"mode-changed","mode":"service"}"#])
        client.close()
    }

    @Test func noSendInitialSkipsSnapshot() async throws {
        let asked = Box(false)
        let (server, path) = try makeServer(initialEvents: { _ in
            asked.value = true
            return [.modeChanged(mode: "main")]
        })
        defer { server.stop() }
        let client = try await onThread { try self.subscribe(path, ["--all", "--no-send-initial"]) }
        #expect(await eventually { server.hasSubscribers(for: .bindingTriggered) })
        server.broadcast(.bindingTriggered(mode: "main", binding: "alt-1"))
        #expect(try await onThread { try self.readEvent(client) } == #"{"_event":"binding-triggered","binding":"alt-1","mode":"main"}"#)
        #expect(!asked.value)
    }

    @Test func invalidSubscribeArgumentsGetAnAnswer() async throws {
        let (server, path) = try makeServer()
        defer { server.stop() }
        let (failure, help) = try await onThread {
            let client = try IPCClient(path: path)
            return try (client.send(ClientRequest(args: ["subscribe"])), client.send(ClientRequest(args: ["subscribe", "-h"])))
        }
        #expect(failure == ServerAnswer(exitCode: 2, stderr: "Either --all or at least one <event> must be specified", serverVersionAndHash: version))
        #expect(help == ServerAnswer(exitCode: 0, stdout: SubscribeArguments.help, serverVersionAndHash: version))
    }

    @Test func disconnectRemovesSubscriber() async throws {
        let (server, path) = try makeServer(initialEvents: { _ in [.modeChanged(mode: "main")] })
        defer { server.stop() }
        // Reading the initial event proves each subscription is registered.
        let clients = try await onThread {
            try (0 ..< 3).map { _ in
                let client = try self.subscribe(path, ["window-detected"])
                _ = try self.readEvent(client)
                return client
            }
        }
        clients[0].close()
        clients[1].close()
        server.broadcast(.windowDetected(windowId: 1, workspace: nil, appBundleId: nil, appName: nil))
        #expect(try await onThread { try self.readEvent(clients[2]) } == #"{"_event":"window-detected","windowId":1}"#)
        clients[2].close()
        #expect(await eventually { !server.hasSubscribers(for: .windowDetected) })
    }

    @Test func subscriberThatStopsReadingIsDropped() async throws {
        let (server, path) = try makeServer()
        defer { server.stop() }
        let client = try await onThread { try self.subscribe(path, ["mode-changed"]) }
        #expect(await eventually { server.hasSubscribers(for: .modeChanged) })
        let mode = String(repeating: "m", count: 4096)
        for _ in 0 ..< 2000 { server.broadcast(.modeChanged(mode: mode)) }
        #expect(await eventually(timeout: 10) { !server.hasSubscribers(for: .modeChanged) })
        client.close()
    }

    @Test func stopDisconnectsSubscribers() async throws {
        let (server, path) = try makeServer()
        let client = try await onThread { try self.subscribe(path, ["--all", "--no-send-initial"]) }
        #expect(await eventually { server.hasSubscribers(for: .focusChanged) })
        server.stop()
        #expect(throws: IPCClientError.connectionClosed) { try client.readFrame() }
    }
}
