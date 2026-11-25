import Combine
import Foundation
import SilkConfig

/// The Settings window's values, kept in the user defaults (as JSON under one key).
@MainActor
final class SettingsStore: ObservableObject {
    private static let key = "settings"
    private let defaults: UserDefaults

    @Published var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: Self.key) }
            onChange?(oldValue)
        }
    }
    /// Called after a change was saved, with the previous value.
    var onChange: ((AppSettings) -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        settings = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(AppSettings.self, from: $0) } ?? AppSettings()
    }

    /// `load` with the window's rules added to its config.
    func merged(into load: ConfigLoadResult) -> ConfigLoadResult {
        var load = load
        load.config.settingsRules = settings.windowDetectedRules
        return load
    }
}
