import Foundation
import Testing
@testable import SilkConfig

func parse(_ toml: String) -> ConfigLoadResult {
    ConfigLoader.parse(toml, url: nil)
}

extension ConfigLoadResult {
    var errorDescriptions: [String] { errors.map(\.description) }
    var warnings: [ConfigDiagnostic] { diagnostics.filter { $0.severity == .warning } }
}

func fixture(_ name: String) throws -> String {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "toml", subdirectory: "Fixtures"))
    return try String(contentsOf: url, encoding: .utf8)
}

/// A fresh temporary directory, removed when `body` returns.
func withTemporaryDirectory<T>(_ body: (URL) throws -> T) throws -> T {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("silk-config-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: url) }
    return try body(url)
}

func write(_ contents: String, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try contents.write(to: url, atomically: true, encoding: .utf8)
}
