import Darwin
import Foundation

/// Failure of a socket system call or of the framing on top of it.
enum SocketError: Error, CustomStringConvertible {
    /// The peer closed the connection (clean EOF).
    case endOfStream
    /// A send did not complete within the socket's send timeout.
    case timedOut
    /// A frame announced a payload larger than the reader accepts.
    case frameTooLarge(UInt32)
    /// A system call failed.
    case system(String, errno: Int32)

    var description: String {
        switch self {
            case .endOfStream: "Connection closed by peer"
            case .timedOut: "Socket send timed out"
            case .frameTooLarge(let size): "Frame of \(size) bytes exceeds the limit"
            case .system(let call, let code): "\(call) failed: \(String(cString: strerror(code))) (errno \(code))"
        }
    }

    static func lastError(_ call: String) -> SocketError { .system(call, errno: errno) }
}

/// An owned, blocking `AF_UNIX` stream socket.
///
/// Reads and writes happen from at most one thread each. ``shutdown()`` may be called from any thread to wake
/// them up; ``close()`` is for the owner once no other thread uses the socket any more. Both are idempotent,
/// and `shutdown()` after `close()` is a no-op, so a descriptor number the kernel has reused is never touched.
final class UnixSocket: @unchecked Sendable {
    private let lock = NSLock()
    private var fd: Int32

    /// Takes ownership of `fd`, marks it close-on-exec and disables `SIGPIPE`.
    init(adopting fd: Int32) {
        self.fd = fd
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    deinit { close() }

    /// A new unconnected stream socket.
    static func make() throws(SocketError) -> UnixSocket {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw .lastError("socket") }
        return UnixSocket(adopting: fd)
    }

    /// The descriptor, or -1 once closed. Only for `poll`/`accept`/`getsockopt` by the owner.
    var descriptor: Int32 {
        lock.withLock { fd }
    }

    func close() {
        lock.withLock {
            if fd >= 0 {
                Darwin.close(fd)
                fd = -1
            }
        }
    }

    /// Wakes up any thread blocked in a read or write on this socket; they fail with EOF / `EPIPE`.
    func shutdown() {
        lock.withLock {
            if fd >= 0 { _ = Darwin.shutdown(fd, SHUT_RDWR) }
        }
    }

    /// Bounds blocking writes, so a client that stops reading cannot wedge a writer forever.
    func setSendTimeout(seconds: Int) {
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        _ = setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    func connect(to path: String) throws(SocketError) {
        var address = try Self.address(path)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { throw .lastError("connect") }
    }

    func bind(to path: String) throws(SocketError) {
        var address = try Self.address(path)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { throw .lastError("bind") }
    }

    func listen(backlog: Int32) throws(SocketError) {
        guard Darwin.listen(descriptor, backlog) == 0 else { throw .lastError("listen") }
    }

    /// The connecting process of an accepted socket (`LOCAL_PEERPID`).
    var peerPID: pid_t? {
        var pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        return getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0 ? pid : nil
    }

    /// The effective uid of the peer (`getpeereid`).
    var peerUID: uid_t? {
        var uid: uid_t = 0
        var gid: gid_t = 0
        return getpeereid(descriptor, &uid, &gid) == 0 ? uid : nil
    }

    // MARK: I/O

    func readExactly(_ count: Int) throws(SocketError) -> Data {
        var data = Data(count: count)
        var offset = 0
        while offset < count {
            let fd = descriptor
            let n = data.withUnsafeMutableBytes { buffer in
                Darwin.read(fd, buffer.baseAddress! + offset, count - offset)
            }
            if n > 0 {
                offset += n
            } else if n == 0 {
                throw .endOfStream
            } else if errno != EINTR {
                throw errno == ECONNRESET ? .endOfStream : .lastError("read")
            }
        }
        return data
    }

    /// Reads and discards input until EOF or an error. Used to detect a `subscribe` client going away.
    func drainUntilClosed() {
        var buffer = [UInt8](repeating: 0, count: 1024)
        while true {
            let n = Darwin.read(descriptor, &buffer, buffer.count)
            if n == 0 || (n < 0 && errno != EINTR) { return }
        }
    }

    func writeAll(_ data: Data) throws(SocketError) {
        var offset = 0
        while offset < data.count {
            let fd = descriptor
            let n = data.withUnsafeBytes { buffer in
                Darwin.write(fd, buffer.baseAddress! + offset, data.count - offset)
            }
            if n >= 0 {
                offset += n
            } else if errno == EAGAIN {
                throw .timedOut
            } else if errno != EINTR {
                throw .lastError("write")
            }
        }
    }

    func readUInt32() throws(SocketError) -> UInt32 {
        WireProtocol.decodeUInt32(try readExactly(4))!
    }

    /// Reads one length-prefixed frame.
    func readFrame(maxPayload: Int) throws(SocketError) -> Data {
        let length = try readUInt32()
        guard Int(length) <= maxPayload else { throw .frameTooLarge(length) }
        return length == 0 ? Data() : try readExactly(Int(length))
    }

    func writeFrame(_ payload: Data) throws(SocketError) {
        try writeAll(WireProtocol.frame(payload))
    }

    // MARK: Addresses

    /// `sockaddr_un` for `path`; throws `ENAMETOOLONG` beyond the 103 usable bytes of `sun_path`.
    private static func address(_ path: String) throws(SocketError) -> sockaddr_un {
        var address = sockaddr_un()
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else { throw .system("sockaddr_un", errno: ENAMETOOLONG) }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        return address
    }
}
