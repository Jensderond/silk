import Foundation

/// Constants and framing of the AeroSpace client/server socket protocol (AeroSpace 0.21,
/// `Sources/Common/util/NWConnectionEx.swift` and `docs/guide.adoc#socket-protocol`).
///
/// 1. Handshake: the client writes its protocol version as a 4-byte unsigned integer, the server
///    answers with its own (always, even when it does not support the client's), then both sides
///    drop the connection if the versions differ.
/// 2. Every message after the handshake, in both directions, is a frame: a 4-byte payload length
///    followed by that many bytes of UTF-8 JSON.
///
/// AeroSpace writes integers in host byte order; every Mac is little-endian, so Silk spells it out.
public enum WireProtocol {
    /// `SOCKET_PROTOCOL_VERSION`. The only version AeroSpace 0.21 knows.
    public static let version: UInt32 = 1

    /// Exit code AeroSpace uses for every failure that is not a conditional `false`.
    public static let failureExitCode: Int32 = 2

    /// Largest payload a server accepts from a client (requests are tiny; `stdin` is capped at 1000 lines by the CLI).
    static let maxRequestPayload = 16 << 20

    /// Largest payload a client accepts from a server (`list-windows --json` on a huge desktop is far below this).
    static let maxAnswerPayload = 256 << 20

    /// Encodes `value` as the 4 little-endian bytes AeroSpace puts on the wire.
    public static func encodeUInt32(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    /// Decodes 4 little-endian bytes; `nil` unless `data` is exactly 4 bytes long.
    public static func decodeUInt32(_ data: Data) -> UInt32? {
        guard data.count == 4 else { return nil }
        return data.reduce(into: (value: UInt32(0), shift: UInt32(0))) { acc, byte in
            acc.value |= UInt32(byte) << acc.shift
            acc.shift += 8
        }.value
    }

    /// Length prefix + payload.
    public static func frame(_ payload: Data) -> Data {
        precondition(payload.count <= Int(UInt32.max), "IPC frame payload too large")
        var data = encodeUInt32(UInt32(payload.count))
        data.append(payload)
        return data
    }

    /// Encoder for `ClientRequest` and `ServerAnswer` frames: AeroSpace's `writeAtomic` default `JSONEncoder()`.
    static func makeMessageEncoder() -> JSONEncoder { JSONEncoder() }

    /// Encoder for `subscribe` event frames, as AeroSpace's `subscriptions.swift` configures it.
    static func makeEventEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        return encoder
    }
}
