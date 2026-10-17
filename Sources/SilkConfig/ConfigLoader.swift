import Foundation
import TOMLDecoder

/// Config file discovery and loading.
///
/// Silk files (`~/.silk.toml`, `$XDG_CONFIG_HOME/silk/silk.toml`) take precedence over AeroSpace files
/// (`~/.aerospace.toml`, `$XDG_CONFIG_HOME/aerospace/aerospace.toml`), so an unmodified AeroSpace config
/// just works and can later be overridden by a Silk-specific one. Within each group, finding both files is an
/// ambiguity error (AeroSpace rule). With no config file at all, the bundled default config is used.
public enum ConfigLoader {
    /// All candidate locations in precedence order: the two Silk files, then the two AeroSpace files.
    public static func candidateURLs(
        home: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [URL] {
        let configHome = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? home.appendingPathComponent(".config", isDirectory: true)
        return [
            home.appendingPathComponent(".silk.toml"),
            configHome.appendingPathComponent("silk/silk.toml"),
            home.appendingPathComponent(".aerospace.toml"),
            configHome.appendingPathComponent("aerospace/aerospace.toml"),
        ]
    }

    public static func load(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ConfigLoadResult {
        let candidates = candidateURLs(home: home, environment: environment)
        for group in [Array(candidates[0 ..< 2]), Array(candidates[2 ..< 4])] {
            let existing = group.filter(exists)
            switch existing.count {
                case 0: continue
                case 1: return load(contentsOf: existing[0])
                default:
                    let message = "Ambiguous config error. Several configs found:\n" + existing.map(\.path).joined(separator: "\n")
                    return fatal(url: nil, message)
            }
        }
        return ConfigLoadResult(config: defaultConfig, url: nil, diagnostics: [], isFatal: false)
    }

    /// Loads a specific file (symlinks are followed).
    public static func load(contentsOf url: URL) -> ConfigLoadResult {
        let source: String
        do {
            source = try String(contentsOf: url, encoding: .utf8)
        } catch {
            return fatal(url: url, "Can't read contents of '\(url.path)' as a utf8 string: \(error.localizedDescription)")
        }
        return parse(source, url: url)
    }

    /// Parses config source. TOML syntax errors are fatal (the default config is returned); schema errors are not:
    /// the offending keys keep their defaults and everything else applies.
    public static func parse(_ toml: String, url: URL?) -> ConfigLoadResult {
        switch parseSource(toml) {
            case .success(let parsed):
                return ConfigLoadResult(config: parsed.config, url: url, diagnostics: parsed.diagnostics, isFatal: false)
            case .failure(let syntaxError):
                return fatal(url: url, syntaxError.description)
        }
    }

    /// The bundled `default-config.toml`, used when no config file exists.
    public static let defaultConfig: Config = {
        guard let url = defaultConfigURL, let source = try? String(contentsOf: url, encoding: .utf8)
        else { fatalError("default-config.toml is missing from the SilkConfig resource bundle") }
        switch parseSource(source) {
            case .success(let parsed) where !parsed.diagnostics.contains { $0.severity == .error }:
                return parsed.config
            case .success(let parsed):
                fatalError("Can't parse the default config: \(parsed.diagnostics)")
            case .failure(let syntaxError):
                fatalError("Can't parse the default config: \(syntaxError)")
        }
    }()

    static var defaultConfigURL: URL? {
        Bundle.module.url(forResource: "default-config", withExtension: "toml")
    }

    private static func parseSource(_ toml: String) -> Result<(config: Config, diagnostics: [ConfigDiagnostic]), TOMLError> {
        var conversionDiagnostics: [ConfigDiagnostic] = []
        let root: [String: TOMLValue]
        do {
            root = try TOMLValue.parse(toml, diagnostics: &conversionDiagnostics)
        } catch {
            return .failure(error)
        }
        var parser = ConfigParser()
        let config = parser.parseRoot(root)
        return .success((config, conversionDiagnostics + parser.diagnostics))
    }

    private static func fatal(url: URL?, _ message: String) -> ConfigLoadResult {
        ConfigLoadResult(config: defaultConfig, url: url, diagnostics: [ConfigDiagnostic(.error, "", message)], isFatal: true)
    }

    /// Existing files, symlinks to them, and also dangling symlinks: a broken symlink should surface as a read
    /// error rather than silently falling back to another (or the default) config.
    private static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
            || (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }
}
