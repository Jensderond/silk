import Foundation
@testable import SilkConfig
import Testing

@Suite struct ConfigLoaderTests {
    @Test func candidateOrder() {
        let home = URL(fileURLWithPath: "/Users/me", isDirectory: true)
        #expect(ConfigLoader.candidateURLs(home: home, environment: [:]).map(\.path) == [
            "/Users/me/.silk.toml",
            "/Users/me/.config/silk/silk.toml",
            "/Users/me/.aerospace.toml",
            "/Users/me/.config/aerospace/aerospace.toml",
        ])
        #expect(ConfigLoader.candidateURLs(home: home, environment: ["XDG_CONFIG_HOME": "/xdg"]).map(\.path) == [
            "/Users/me/.silk.toml",
            "/xdg/silk/silk.toml",
            "/Users/me/.aerospace.toml",
            "/xdg/aerospace/aerospace.toml",
        ])
    }

    @Test func silkConfigTakesPrecedenceOverAeroSpaceConfig() throws {
        try withTemporaryDirectory { home in
            try write("accordion-padding = 1", to: home.appendingPathComponent(".aerospace.toml"))
            try write("accordion-padding = 2", to: home.appendingPathComponent(".config/aerospace/aerospace.toml"))
            try write("accordion-padding = 3", to: home.appendingPathComponent(".config/silk/silk.toml"))
            let result = ConfigLoader.load(home: home, environment: [:])
            #expect(!result.isFatal)
            #expect(result.url?.lastPathComponent == "silk.toml")
            #expect(result.config.accordionPadding == 3)
        }
    }

    @Test func singleAeroSpaceConfigIsUsed() throws {
        try withTemporaryDirectory { home in
            let xdg = home.appendingPathComponent("xdg")
            try write("accordion-padding = 4", to: xdg.appendingPathComponent("aerospace/aerospace.toml"))
            let result = ConfigLoader.load(home: home, environment: ["XDG_CONFIG_HOME": xdg.path])
            #expect(result.url == xdg.appendingPathComponent("aerospace/aerospace.toml"))
            #expect(result.config.accordionPadding == 4)
        }
    }

    @Test func bothSilkConfigsAreAmbiguous() throws {
        try withTemporaryDirectory { home in
            try write("", to: home.appendingPathComponent(".silk.toml"))
            try write("", to: home.appendingPathComponent(".config/silk/silk.toml"))
            try write("", to: home.appendingPathComponent(".aerospace.toml"))
            let result = ConfigLoader.load(home: home, environment: [:])
            #expect(result.isFatal)
            #expect(result.url == nil)
            #expect(result.config == ConfigLoader.defaultConfig)
            #expect(result.errors.first?.message.hasPrefix("Ambiguous config error. Several configs found:\n") == true)
            #expect(result.errors.first?.message.contains(".config/silk/silk.toml") == true)
        }
    }

    @Test func bothAeroSpaceConfigsAreAmbiguousWithoutSilkConfig() throws {
        try withTemporaryDirectory { home in
            try write("", to: home.appendingPathComponent(".aerospace.toml"))
            try write("", to: home.appendingPathComponent(".config/aerospace/aerospace.toml"))
            #expect(ConfigLoader.load(home: home, environment: [:]).isFatal)

            try write("accordion-padding = 5", to: home.appendingPathComponent(".silk.toml"))
            let result = ConfigLoader.load(home: home, environment: [:])
            #expect(!result.isFatal, "A Silk config resolves the AeroSpace ambiguity")
            #expect(result.config.accordionPadding == 5)
        }
    }

    @Test func symlinksAreFollowed() throws {
        try withTemporaryDirectory { home in
            let target = home.appendingPathComponent(".dotfiles/aerospace/.aerospace.toml")
            try write("accordion-padding = 6", to: target)
            try FileManager.default.createSymbolicLink(
                atPath: home.appendingPathComponent(".aerospace.toml").path,
                withDestinationPath: ".dotfiles/aerospace/.aerospace.toml"
            )
            let result = ConfigLoader.load(home: home, environment: [:])
            #expect(result.url == home.appendingPathComponent(".aerospace.toml"))
            #expect(result.config.accordionPadding == 6)
        }
    }

    @Test func danglingSymlinkIsAReadError() throws {
        try withTemporaryDirectory { home in
            try FileManager.default.createSymbolicLink(
                atPath: home.appendingPathComponent(".aerospace.toml").path,
                withDestinationPath: "missing.toml"
            )
            let result = ConfigLoader.load(home: home, environment: [:])
            #expect(result.isFatal)
            #expect(result.errors.first?.message.hasPrefix("Can't read contents of ") == true)
        }
    }

    @Test func schemaErrorsAreNotFatal() throws {
        try withTemporaryDirectory { home in
            try write("accordion-padding = 'x'\nstart-at-login = true", to: home.appendingPathComponent(".silk.toml"))
            let result = ConfigLoader.load(home: home, environment: [:])
            #expect(!result.isFatal)
            #expect(result.errorDescriptions == ["[ERROR] accordion-padding: Expected type is 'Int'. But actual type is 'String'"])
            #expect(result.config.startAtLogin)
        }
    }
}
