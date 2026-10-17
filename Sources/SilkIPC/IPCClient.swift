import Darwin
import Foundation

/// Why talking to the server failed.
public enum IPCClientError: Error, Equatable, CustomStringConvertible {
    /// No server listens on the path (socket file missing or stale).
    case serverNotRunning(path: String)
    /// The server speaks a different `SOCKET_PROTOCOL_VERSION`.
    case protocolVersionMismatch(server: UInt32)
    /// The server closed the connection.
    case connectionClosed
    /// An answer frame was not a valid `ServerAnswer`.
    case malformedAnswer(String)
    /// Any other socket failure.
    case io(String)

    public var description: String {
        switch self {
            case .serverNotRunning(let path): "No server is listening on \(path)"
            case .protocolVersionMismatch(let server):
                """
                Client SOCKET_PROTOCOL_VERSION: \(WireProtocol.version)
                Server SOCKET_PROTOCOL_VERSION: \(server)

                The client and server versions are incompatible. (Potential fix: restart Silk)
                """
            case .connectionClosed: "The server closed the connection"
            case .malformedAnswer(let raw): "Failed to parse server response: \(raw)"
            case .io(let message): message
        }
    }
}

/// A blocking client connection, as used by the `silk` CLI.
///
/// ```swift
/// let client = try IPCClient(path: IPCEndpoint.silkSocketPath)
/// let answer = try client.send(ClientRequest(args: ["list-workspaces", "--focused"]))
/// ```
///
/// Not thread-safe: use one connection from one thread. Several requests may be sent on one connection;
/// after a `subscribe` request, only ``readFrame()`` is valid.
public final class IPCClient {
    private let socket: UnixSocket

    /// Connects and performs the protocol-version handshake.
    public init(path: String) throws(IPCClientError) {
        do throws(SocketError) {
            socket = try UnixSocket.make()
            try socket.connect(to: path)
        } catch .system(_, let code) where code == ENOENT || code == ECONNREFUSED {
            throw .serverNotRunning(path: path)
        } catch {
            throw Self.map(error)
        }
        let serverVersion: UInt32
        do throws(SocketError) {
            try socket.writeAll(WireProtocol.encodeUInt32(WireProtocol.version))
            serverVersion = try socket.readUInt32()
        } catch {
            throw Self.map(error)
        }
        guard serverVersion == WireProtocol.version else { throw .protocolVersionMismatch(server: serverVersion) }
    }

    /// Sends a request without waiting for anything (use before ``readFrame()`` for `subscribe`).
    public func write(_ request: ClientRequest) throws(IPCClientError) {
        let payload: Data
        do {
            payload = try WireProtocol.makeMessageEncoder().encode(request)
        } catch {
            throw .io("Can't encode request: \(error)")
        }
        do throws(SocketError) {
            try socket.writeFrame(payload)
        } catch {
            throw Self.map(error)
        }
    }

    /// Reads one raw frame payload (a `ServerAnswer` or, on a subscription, a `ServerEvent`).
    public func readFrame() throws(IPCClientError) -> Data {
        do throws(SocketError) {
            return try socket.readFrame(maxPayload: WireProtocol.maxAnswerPayload)
        } catch {
            throw Self.map(error)
        }
    }

    /// Sends a one-shot request and waits for its answer.
    public func send(_ request: ClientRequest) throws(IPCClientError) -> ServerAnswer {
        try write(request)
        let frame = try readFrame()
        guard let answer = try? JSONDecoder().decode(ServerAnswer.self, from: frame) else {
            throw .malformedAnswer(String(decoding: frame, as: UTF8.self))
        }
        return answer
    }

    /// Closes the connection (also done on deinit).
    public func close() {
        socket.close()
    }

    private static func map(_ error: SocketError) -> IPCClientError {
        switch error {
            case .endOfStream: .connectionClosed
            case .system(_, let code) where code == EPIPE || code == ECONNRESET: .connectionClosed
            default: .io(error.description)
        }
    }
}
