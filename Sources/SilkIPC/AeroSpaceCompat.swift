import Darwin
import Foundation

/// Facts about the AeroSpace release whose CLI and wire protocol Silk implements.
public enum AeroSpaceCompat {
    /// `serverVersionAndHash` of AeroSpace 0.21.3-Beta, the release Silk mirrors. Reported on AeroSpace's socket
    /// when the connecting client's own version can't be determined (see ``IPCEndpoint/VersionReporting``).
    public static let targetVersionAndHash = "0.21.3-Beta d56e1637c3a1ed660d0cadd7534e94fb3218d1c3"

    /// AeroSpace's release socket, `/tmp/bobko.aerospace-<NSUserName()>.sock` (`Common/util/commonUtil.swift`).
    public static var socketPath: String { "/tmp/bobko.aerospace-\(NSUserName()).sock" }
}

/// Recovers the `"<version> <git hash>"` an AeroSpace CLI binary compares server answers against.
///
/// The AeroSpace CLI builds `cliClientVersionAndHash` from two global string constants. The 40-character git
/// hash is a large Swift string, stored as a NUL-terminated C string; the version (e.g. `0.21.3-Beta`, at most
/// 15 UTF-8 bytes) is a small Swift string, stored inline as a 16-byte record: the bytes, zero padding, and a
/// final discriminator byte `0xE0 | count`. The probe scans the executable for both and only answers when each
/// is unambiguous (a universal binary contains every constant once per slice). Results are cached per
/// (path, size, modification date), so each CLI binary is scanned once per server lifetime.
final class AeroSpaceClientVersionProbe: @unchecked Sendable {
    private struct FileKey: Hashable {
        let path: String
        let size: Int
        let modified: Date
    }

    private let lock = NSLock()
    private var cache: [FileKey: String?] = [:]

    /// Executables larger than this are not AeroSpace CLIs (0.21.3 is 2.6 MB universal).
    private static let maxExecutableSize = 64 << 20

    /// Where package managers put the `aerospace` CLI; scanned ahead of time by ``warmUp()``.
    static let wellKnownCLIPaths = ["/opt/homebrew/bin/aerospace", "/usr/local/bin/aerospace"]

    /// Scans the well-known CLI locations in the background (a scan takes tens of milliseconds), so the first
    /// `aerospace` call after the server starts isn't slowed down.
    func warmUp() {
        DispatchQueue.global(qos: .utility).async { [self] in
            for path in Self.wellKnownCLIPaths where FileManager.default.fileExists(atPath: path) {
                _ = versionAndHash(ofExecutableAt: URL(fileURLWithPath: path).resolvingSymlinksInPath().path)
            }
        }
    }

    /// The version string of the executable running as `pid`, if it is an AeroSpace CLI.
    func versionAndHash(ofProcess pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return versionAndHash(ofExecutableAt: String(cString: buffer))
    }

    func versionAndHash(ofExecutableAt path: String) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attributes[.size] as? NSNumber)?.intValue,
              let modified = attributes[.modificationDate] as? Date
        else { return nil }
        let key = FileKey(path: path, size: size, modified: modified)
        if let cached = lock.withLock({ cache[key] }) { return cached }
        let result: String? = if size <= Self.maxExecutableSize,
                                 let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped) {
            Self.scan(data)
        } else {
            nil
        }
        lock.withLock { cache[key] = result }
        return result
    }

    static func scan(_ data: Data) -> String? {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> String? in
            let bytes = raw.bindMemory(to: UInt8.self)
            guard let hash = unique(gitHashes(bytes)), let version = unique(smallStringVersions(bytes)) else { return nil }
            return "\(version) \(hash)"
        }
    }

    private static func unique(_ values: Set<String>) -> String? {
        values.count == 1 ? values.first : nil
    }

    /// NUL-delimited runs of exactly 40 lowercase hex digits.
    private static func gitHashes(_ bytes: UnsafeBufferPointer<UInt8>) -> Set<String> {
        var result: Set<String> = []
        var runStart = -1
        for i in 0 ..< bytes.count {
            let byte = bytes[i]
            if isLowerHex(byte) {
                if runStart < 0 { runStart = i }
                continue
            }
            if byte == 0, runStart > 0, i - runStart == 40, bytes[runStart - 1] == 0 {
                result.insert(String(decoding: UnsafeBufferPointer(rebasing: bytes[runStart ..< i]), as: UTF8.self))
            }
            runStart = -1
        }
        return result
    }

    /// 8-byte aligned inline small-string records whose contents look like `MAJOR.MINOR.PATCH[-SUFFIX]`.
    private static func smallStringVersions(_ bytes: UnsafeBufferPointer<UInt8>) -> Set<String> {
        var result: Set<String> = []
        var offset = 0
        while offset + 16 <= bytes.count {
            defer { offset += 8 }
            let discriminator = bytes[offset + 15]
            guard discriminator & 0xF0 == 0xE0 else { continue }
            let count = Int(discriminator & 0x0F)
            guard count >= 5, (offset + count ..< offset + 15).allSatisfy({ bytes[$0] == 0 }) else { continue }
            let candidate = UnsafeBufferPointer(rebasing: bytes[offset ..< offset + count])
            if isVersion(candidate) {
                result.insert(String(decoding: candidate, as: UTF8.self))
            }
        }
        return result
    }

    private static func isLowerHex(_ byte: UInt8) -> Bool {
        (0x30 ... 0x39).contains(byte) || (0x61 ... 0x66).contains(byte)
    }

    /// `\d+\.\d+\.\d+(-[A-Za-z0-9.]+)?`
    private static func isVersion(_ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        let isDigit = { (byte: UInt8) in (0x30 ... 0x39).contains(byte) }
        var index = 0
        for component in 0 ..< 3 {
            let start = index
            while index < bytes.count, isDigit(bytes[index]) { index += 1 }
            guard index > start else { return false }
            if component < 2 {
                guard index < bytes.count, bytes[index] == UInt8(ascii: ".") else { return false }
                index += 1
            }
        }
        if index == bytes.count { return true }
        guard bytes[index] == UInt8(ascii: "-"), index + 1 < bytes.count else { return false }
        return bytes[(index + 1)...].allSatisfy { byte in
            isDigit(byte) || (0x41 ... 0x5A).contains(byte) || (0x61 ... 0x7A).contains(byte) || byte == UInt8(ascii: ".")
        }
    }
}
