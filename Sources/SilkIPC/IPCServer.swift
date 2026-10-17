import Darwin
import Foundation

/// The AeroSpace-compatible socket server.
///
/// Listens on one or more Unix-domain stream sockets (typically ``IPCEndpoint/silk(version:)`` and
/// ``IPCEndpoint/aerospace``), speaks AeroSpace's wire protocol on each, and hands every one-shot command to a
/// handler on `handlerQueue` (main by default). `subscribe` is handled here, as in AeroSpace's `server.swift`:
/// its arguments are parsed with AeroSpace's rules, the initial state comes from `initialEvents`, and later
/// events are pushed with ``broadcast(_:)``.
///
/// Threads: one accept thread polls all listening sockets; every connection gets its own thread doing
/// blocking I/O, so slow clients never stall each other or the handler queue. Socket writes never happen on
/// the handler queue. Event delivery to each subscriber runs on a private serial queue; a subscriber that
/// stops reading (send timeout or 512 undelivered events) is disconnected.
///
/// ```swift
/// let server = IPCServer(endpoints: [.silk(), .aerospace], initialEvents: { engine.subscribeSnapshot($0) }) { request, reply in
///     let result = engine.run(args: request.args, stdin: request.stdin)
///     reply.send(exitCode: result.exitCode, stdout: result.stdout, stderr: result.stderr)
/// }
/// do { try server.start() } catch .endpointInUse(let endpoint) where endpoint.path == AeroSpaceCompat.socketPath {
///     // "AeroSpace is running"
/// }
/// ```
public final class IPCServer: @unchecked Sendable {
    /// Runs one command. Called on the handler queue; must eventually call ``IPCReply/send(exitCode:stdout:stderr:)``
    /// (from any thread). AeroSpace parity the handler is responsible for: append
    /// ``ClientRequest/missingContextFieldsWarning`` to `stderr` of successfully parsed commands when
    /// ``ClientRequest/hasContextFields`` is `false`, and refuse non-`enable` commands while disabled.
    public typealias Handler = (ClientRequest, IPCReply) -> Void

    /// The current state for a new `subscribe` client, in emission order. Called on the handler queue unless
    /// the client passed `--no-send-initial`. AeroSpace sends one event per subscribed kind except
    /// `window-detected` and `binding-triggered`.
    public typealias InitialEventsProvider = (Set<ServerEventType>) -> [ServerEvent]

    private let core: ServerCore

    /// - Parameters:
    ///   - endpoints: sockets to listen on, bound in this order by ``start()``.
    ///   - handlerQueue: where `handler`, `initialEvents` and `onEndpointLost` run.
    ///   - initialEvents: state snapshot for new subscribers.
    ///   - onEndpointLost: called once per endpoint when another process replaces its socket file (AeroSpace
    ///     unconditionally deletes and rebinds its path on launch); the server stops serving that endpoint.
    ///     A socket file that merely disappears is recreated silently.
    ///   - handler: runs one-shot commands.
    public init(
        endpoints: [IPCEndpoint],
        handlerQueue: DispatchQueue = .main,
        initialEvents: @escaping InitialEventsProvider,
        onEndpointLost: ((IPCEndpoint) -> Void)? = nil,
        handler: @escaping Handler
    ) {
        core = ServerCore(
            endpoints: endpoints,
            handlerQueue: handlerQueue,
            handler: handler,
            initialEvents: initialEvents,
            onEndpointLost: onEndpointLost
        )
    }

    deinit { core.stop() }

    /// Binds every endpoint and starts accepting connections.
    ///
    /// A leftover socket file nobody listens on is removed first. If any endpoint is unusable, nothing stays
    /// bound and the first problem is thrown: ``IPCServerError/endpointInUse(_:)`` when a live server answers
    /// on it. Socket files are created with mode `0600`.
    public func start() throws(IPCServerError) {
        try core.start()
    }

    /// Stops accepting, disconnects every client and removes the socket files this server created (only if
    /// they are still the ones it bound). Idempotent; a stopped server can't be restarted.
    public func stop() {
        core.stop()
    }

    /// Sends `event` to every subscriber of its kind. Thread-safe and non-blocking.
    public func broadcast(_ event: ServerEvent) {
        core.broadcast(event)
    }

    /// Whether any connected client subscribed to `type`, to skip building events nobody receives.
    public func hasSubscribers(for type: ServerEventType) -> Bool {
        core.hasSubscribers(for: type)
    }

    /// Endpoints currently being served (shrinks when one is lost to another process).
    public var activeEndpoints: [IPCEndpoint] {
        core.activeEndpoints
    }

    /// For tests: how often socket files are checked for replacement or removal.
    var watchdogInterval: TimeInterval {
        get { core.watchdogInterval }
        set { core.watchdogInterval = newValue }
    }
}

/// Why ``IPCServer/start()`` failed.
public enum IPCServerError: Error, Equatable, CustomStringConvertible {
    /// `start()` was called before.
    case alreadyStarted
    /// Another live server accepts connections on this endpoint's socket (AeroSpace, or another Silk).
    case endpointInUse(IPCEndpoint)
    /// The path exists and is not a socket; Silk does not delete it.
    case notASocket(path: String)
    /// The path does not fit into `sockaddr_un` (103 bytes).
    case pathTooLong(path: String)
    /// A system call failed.
    case system(path: String, message: String)

    public var description: String {
        switch self {
            case .alreadyStarted: "The IPC server was already started"
            case .endpointInUse(let endpoint): "Another server is listening on \(endpoint.path)"
            case .notASocket(let path): "\(path) exists and is not a socket"
            case .pathTooLong(let path): "Socket path is too long: \(path)"
            case .system(let path, let message): "\(path): \(message)"
        }
    }
}

/// The answer channel for one command. Thread-safe; the first ``send(exitCode:stdout:stderr:)`` wins.
///
/// Dropping the last reference without sending answers the client with exit code 2 and an internal-error
/// message, so a buggy command path never leaves a CLI hanging.
public final class IPCReply: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: ((Int32, String, String) -> Void)?

    init(completion: @escaping (Int32, String, String) -> Void) {
        self.completion = completion
    }

    deinit {
        completion?(WireProtocol.failureExitCode, "", "Silk did not answer this request (internal error)")
    }

    /// Answers the client. `serverVersionAndHash` is filled in by the server.
    public func send(exitCode: Int32, stdout: String = "", stderr: String = "") {
        let completion = lock.withLock {
            defer { self.completion = nil }
            return self.completion
        }
        completion?(exitCode, stdout, stderr)
    }
}

// MARK: - Implementation

private struct Listener {
    let endpoint: IPCEndpoint
    let socket: UnixSocket
    let device: dev_t
    let inode: ino_t

    /// Whether `endpoint.path` still is the socket file this listener created.
    var ownsPath: Bool {
        var info = stat()
        return lstat(endpoint.path, &info) == 0 && info.st_dev == device && info.st_ino == inode
    }
}

final class ServerCore: @unchecked Sendable {
    private enum State { case idle, running, stopped }

    let handlerQueue: DispatchQueue
    let handler: IPCServer.Handler
    let initialEvents: IPCServer.InitialEventsProvider
    let versionProbe = AeroSpaceClientVersionProbe()
    private let endpoints: [IPCEndpoint]
    private let onEndpointLost: ((IPCEndpoint) -> Void)?

    private let lock = NSLock()
    private var state = State.idle
    private var listeners: [Listener] = []
    private var connections: [ObjectIdentifier: ClientConnection] = [:]
    private var subscribers: [ObjectIdentifier: Subscriber] = [:]
    private var wakeRead: Int32 = -1
    private var wakeWrite: Int32 = -1
    private var watchdogIntervalStorage: TimeInterval = 2
    private let acceptLoopFinished = DispatchSemaphore(value: 0)

    /// Send timeout of client sockets: bounds how long a non-reading client can hold a writer.
    static let sendTimeoutSeconds = 5

    init(
        endpoints: [IPCEndpoint],
        handlerQueue: DispatchQueue,
        handler: @escaping IPCServer.Handler,
        initialEvents: @escaping IPCServer.InitialEventsProvider,
        onEndpointLost: ((IPCEndpoint) -> Void)?
    ) {
        self.endpoints = endpoints
        self.handlerQueue = handlerQueue
        self.handler = handler
        self.initialEvents = initialEvents
        self.onEndpointLost = onEndpointLost
    }

    var watchdogInterval: TimeInterval {
        get { lock.withLock { watchdogIntervalStorage } }
        set { lock.withLock { watchdogIntervalStorage = newValue } }
    }

    var activeEndpoints: [IPCEndpoint] {
        lock.withLock { listeners.map(\.endpoint) }
    }

    // MARK: Lifecycle

    func start() throws(IPCServerError) {
        lock.lock()
        defer { lock.unlock() }
        guard state == .idle else { throw .alreadyStarted }
        var bound: [Listener] = []
        do throws(IPCServerError) {
            for endpoint in endpoints {
                bound.append(try Self.bind(endpoint))
            }
        } catch {
            for listener in bound { Self.release(listener) }
            throw error
        }
        var pipeFDs: [Int32] = [-1, -1]
        guard pipe(&pipeFDs) == 0 else {
            let message = String(cString: strerror(errno))
            for listener in bound { Self.release(listener) }
            throw .system(path: "pipe", message: message)
        }
        for fd in pipeFDs { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        (wakeRead, wakeWrite) = (pipeFDs[0], pipeFDs[1])
        listeners = bound
        state = .running
        if endpoints.contains(where: { if case .mirrorAeroSpaceClient = $0.versionReporting { true } else { false } }) {
            versionProbe.warmUp()
        }
        let thread = Thread { [self] in acceptLoop() }
        thread.name = "silk.ipc.accept"
        thread.start()
    }

    func stop() {
        let (wasRunning, closing, active) = lock.withLock {
            defer {
                state = .stopped
                listeners = []
            }
            return (state == .running, listeners, Array(connections.values))
        }
        guard wasRunning else { return }
        var byte: UInt8 = 1
        _ = write(wakeWrite, &byte, 1)
        acceptLoopFinished.wait()
        for listener in closing { Self.release(listener) }
        for connection in active { connection.socket.shutdown() }
        Darwin.close(wakeRead)
        Darwin.close(wakeWrite)
    }

    /// Removes the socket file if it is still ours, and closes the listening socket.
    private static func release(_ listener: Listener) {
        if listener.ownsPath { unlink(listener.endpoint.path) }
        listener.socket.close()
    }

    /// Clears a stale socket file, refuses a live one, binds, restricts permissions and listens.
    private static func bind(_ endpoint: IPCEndpoint) throws(IPCServerError) -> Listener {
        let path = endpoint.path
        func failure(_ error: SocketError) -> IPCServerError {
            if case .system(_, let code) = error, code == ENAMETOOLONG { return .pathTooLong(path: path) }
            return .system(path: path, message: error.description)
        }

        var info = stat()
        if lstat(path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFSOCK else { throw .notASocket(path: path) }
            do {
                let probe = try UnixSocket.make()
                defer { probe.close() }
                try probe.connect(to: path)
                throw IPCServerError.endpointInUse(endpoint)
            } catch let error as IPCServerError {
                throw error
            } catch SocketError.system(_, let code) where code == ECONNREFUSED {
                unlink(path) // Stale: the previous owner died without cleaning up.
            } catch let error as SocketError {
                throw failure(error)
            } catch {
                throw .system(path: path, message: "\(error)")
            }
        } else if errno != ENOENT {
            throw .system(path: path, message: String(cString: strerror(errno)))
        }

        let socket: UnixSocket
        do throws(SocketError) {
            socket = try UnixSocket.make()
            try socket.bind(to: path)
        } catch .system(_, let code) where code == EADDRINUSE {
            throw .endpointInUse(endpoint)
        } catch {
            throw failure(error)
        }
        guard chmod(path, 0o600) == 0, lstat(path, &info) == 0 else {
            let message = String(cString: strerror(errno))
            unlink(path)
            socket.close()
            throw .system(path: path, message: message)
        }
        do throws(SocketError) {
            try socket.listen(backlog: 128)
        } catch {
            unlink(path)
            socket.close()
            throw failure(error)
        }
        let flags = fcntl(socket.descriptor, F_GETFL)
        _ = fcntl(socket.descriptor, F_SETFL, flags | O_NONBLOCK)
        return Listener(endpoint: endpoint, socket: socket, device: info.st_dev, inode: info.st_ino)
    }

    // MARK: Accepting

    private func acceptLoop() {
        defer { acceptLoopFinished.signal() }
        var lastCheck = Date()
        while true {
            guard let (current, interval) = lock.withLock({ state == .running ? (listeners, watchdogIntervalStorage) : nil })
            else { return }
            var fds = [pollfd(fd: wakeRead, events: Int16(POLLIN), revents: 0)]
                + current.map { pollfd(fd: $0.socket.descriptor, events: Int16(POLLIN), revents: 0) }
            let ready = poll(&fds, nfds_t(fds.count), Int32(max(interval, 0.01) * 1000))
            if ready < 0 && errno != EINTR { usleep(100_000) }
            if fds[0].revents != 0 { return }
            for (index, listener) in current.enumerated() where fds[index + 1].revents != 0 {
                acceptPending(on: listener)
            }
            if Date().timeIntervalSince(lastCheck) >= interval {
                checkSocketFiles()
                lastCheck = Date()
            }
        }
    }

    private func acceptPending(on listener: Listener) {
        while true {
            let fd = accept(listener.socket.descriptor, nil, nil)
            if fd < 0 {
                if errno == EMFILE || errno == ENFILE { usleep(100_000) } // Out of descriptors: back off.
                return
            }
            let flags = fcntl(fd, F_GETFL) // Accepted sockets inherit O_NONBLOCK on BSD; connections block.
            _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK)
            let socket = UnixSocket(adopting: fd)
            socket.setSendTimeout(seconds: Self.sendTimeoutSeconds)
            let connection = ClientConnection(core: self, socket: socket, endpoint: listener.endpoint)
            let accepted = lock.withLock {
                guard state == .running else { return false }
                connections[ObjectIdentifier(connection)] = connection
                return true
            }
            guard accepted else {
                socket.close()
                return
            }
            let thread = Thread { [self] in
                connection.run()
                lock.withLock { _ = connections.removeValue(forKey: ObjectIdentifier(connection)) }
                connection.socket.close()
            }
            thread.name = "silk.ipc.connection"
            thread.start()
        }
    }

    /// Recreates vanished socket files; gives up endpoints whose path now belongs to someone else.
    private func checkSocketFiles() {
        let current = lock.withLock { listeners }
        for listener in current where !listener.ownsPath {
            var info = stat()
            let vanished = lstat(listener.endpoint.path, &info) != 0 && errno == ENOENT
            listener.socket.close()
            let replacement = vanished ? try? Self.bind(listener.endpoint) : nil
            let stillRunning = lock.withLock {
                guard state == .running, let index = listeners.firstIndex(where: { $0.socket === listener.socket }) else { return false }
                if let replacement { listeners[index] = replacement } else { listeners.remove(at: index) }
                return true
            }
            if let replacement, !stillRunning { Self.release(replacement) }
            if replacement == nil, stillRunning, let onEndpointLost {
                handlerQueue.async { onEndpointLost(listener.endpoint) }
            }
        }
    }

    // MARK: Commands and subscriptions

    /// Runs `request` through the handler and blocks the calling connection thread until it answers.
    func dispatch(_ request: ClientRequest) -> (exitCode: Int32, stdout: String, stderr: String) {
        let done = DispatchSemaphore(value: 0)
        var result = (exitCode: WireProtocol.failureExitCode, stdout: "", stderr: "")
        handlerQueue.async { [handler] in
            // The reply is created here so only the handler owns it: dropping it fires the fallback answer.
            handler(request, IPCReply { exitCode, stdout, stderr in
                result = (exitCode, stdout, stderr)
                done.signal()
            })
        }
        done.wait()
        return result
    }

    /// Queues the initial events and makes `subscriber` visible to ``broadcast(_:)`` atomically.
    func register(_ subscriber: Subscriber, initial: [ServerEvent]) {
        let encoder = WireProtocol.makeEventEncoder()
        let accepted = lock.withLock {
            guard state == .running else { return false }
            for event in initial {
                if let payload = try? encoder.encode(event) { subscriber.enqueue(WireProtocol.frame(payload)) }
            }
            subscribers[ObjectIdentifier(subscriber)] = subscriber
            return true
        }
        if !accepted { subscriber.socket.shutdown() }
    }

    func unregister(_ subscriber: Subscriber) {
        lock.withLock { _ = subscribers.removeValue(forKey: ObjectIdentifier(subscriber)) }
    }

    func broadcast(_ event: ServerEvent) {
        let targets = lock.withLock { subscribers.values.filter { $0.events.contains(event.eventType) } }
        guard !targets.isEmpty, let payload = try? WireProtocol.makeEventEncoder().encode(event) else { return }
        let frame = WireProtocol.frame(payload)
        for subscriber in targets { subscriber.enqueue(frame) }
    }

    func hasSubscribers(for type: ServerEventType) -> Bool {
        lock.withLock { subscribers.values.contains { $0.events.contains(type) } }
    }
}

/// One accepted client, served on its own thread.
final class ClientConnection: @unchecked Sendable {
    let socket: UnixSocket
    private let core: ServerCore
    private let endpoint: IPCEndpoint
    private lazy var serverVersionAndHash: String = switch endpoint.versionReporting {
        case .fixed(let version): version
        case .mirrorAeroSpaceClient(let fallback): socket.peerPID.flatMap(core.versionProbe.versionAndHash(ofProcess:)) ?? fallback
    }

    init(core: ServerCore, socket: UnixSocket, endpoint: IPCEndpoint) {
        self.core = core
        self.socket = socket
        self.endpoint = endpoint
    }

    /// Handshake, then requests until the client disconnects (AeroSpace's `newConnection`).
    func run() {
        guard let uid = socket.peerUID, uid == getuid() || uid == 0 else { return }
        guard let clientVersion = try? socket.readUInt32(),
              (try? socket.writeAll(WireProtocol.encodeUInt32(WireProtocol.version))) != nil,
              clientVersion == WireProtocol.version
        else { return }

        while true {
            let payload: Data
            do throws(SocketError) {
                payload = try socket.readFrame(maxPayload: WireProtocol.maxRequestPayload)
            } catch .endOfStream {
                return
            } catch {
                answer(exitCode: WireProtocol.failureExitCode, stderr: "Error: \(error)")
                return
            }
            let request: ClientRequest
            do {
                request = try JSONDecoder().decode(ClientRequest.self, from: payload)
            } catch {
                let raw = String(decoding: payload, as: UTF8.self)
                guard answer(exitCode: WireProtocol.failureExitCode, stderr: "Can't parse request '\(raw)'.\nError: \(error.localizedDescription)")
                else { return }
                continue
            }
            if request.args.first == "subscribe" {
                switch SubscribeArguments.parse(Array(request.args.dropFirst())) {
                    case .subscribe(let arguments):
                        stream(arguments)
                        return
                    case .help(let help):
                        guard answer(exitCode: 0, stdout: help) else { return }
                    case .failure(let message):
                        guard answer(exitCode: WireProtocol.failureExitCode, stderr: message) else { return }
                }
                continue
            }
            let result = core.dispatch(request)
            guard answer(exitCode: result.exitCode, stdout: result.stdout, stderr: result.stderr) else { return }
        }
    }

    /// Writes one `ServerAnswer`; `false` if the client is gone.
    @discardableResult
    private func answer(exitCode: Int32, stdout: String = "", stderr: String = "") -> Bool {
        let answer = ServerAnswer(exitCode: exitCode, stdout: stdout, stderr: stderr, serverVersionAndHash: serverVersionAndHash)
        guard let payload = try? WireProtocol.makeMessageEncoder().encode(answer) else { return false }
        return (try? socket.writeFrame(payload)) != nil
    }

    /// Turns this connection into an event stream until the client hangs up (`handleSubscribeAndWaitTillError`).
    private func stream(_ arguments: SubscribeArguments) {
        let subscriber = Subscriber(socket: socket, events: arguments.events)
        core.handlerQueue.sync {
            core.register(subscriber, initial: arguments.sendInitial ? core.initialEvents(arguments.events) : [])
        }
        socket.drainUntilClosed()
        core.unregister(subscriber)
        subscriber.waitForPendingWrites()
    }
}

/// Event delivery to one `subscribe` client.
final class Subscriber: @unchecked Sendable {
    let socket: UnixSocket
    let events: Set<ServerEventType>
    private let queue = DispatchQueue(label: "silk.ipc.subscriber")
    private let lock = NSLock()
    private var pending = 0
    private var failed = false

    /// Undelivered events after which a client that doesn't read is disconnected.
    static let maxPendingEvents = 512

    init(socket: UnixSocket, events: Set<ServerEventType>) {
        self.socket = socket
        self.events = events
    }

    func enqueue(_ frame: Data) {
        let accepted = lock.withLock {
            if failed { return false }
            if pending >= Self.maxPendingEvents {
                failed = true
                return false
            }
            pending += 1
            return true
        }
        guard accepted else {
            socket.shutdown()
            return
        }
        queue.async { [self] in
            do {
                try socket.writeAll(frame)
            } catch {
                lock.withLock { failed = true }
                socket.shutdown() // Wakes the connection thread, which unregisters this subscriber.
            }
            lock.withLock { pending -= 1 }
        }
    }

    /// Blocks until every queued write finished; afterwards the socket may be closed.
    func waitForPendingWrites() {
        queue.sync {}
    }
}
