import Foundation
import Testing
@testable import SilkPlatform

/// Port of AeroSpace's `AxUiElementWindowTypeTest`: every dump in AeroSpace's axDumps corpus
/// must classify exactly like AeroSpace does.
struct WindowClassifierCorpusTests {
    struct CorpusEntry: CustomStringConvertible {
        let name: String
        let dump: AXWindowDump
        let app: AppTraits
        let expectedKind: WindowKind
        let expectedIsDialog: Bool
        var description: String { name }
    }

    static let corpus: [CorpusEntry] = loadCorpus()

    @Test func corpusIsComplete() {
        #expect(Self.corpus.count >= 120)
    }

    @Test(arguments: corpus)
    func classifiesLikeAeroSpace(_ entry: CorpusEntry) {
        #expect(WindowClassifier.classify(entry.dump, app: entry.app) == entry.expectedKind, "\(entry.name)")
        #expect(WindowClassifier.isDialog(entry.dump, app: entry.app) == entry.expectedIsDialog, "\(entry.name)")
    }

    @Test func enabledStateIsReadForEveryButtonTheClassifierConsults() {
        #expect(WindowClassifier.buttonsNeedingEnabledState(bundleId: "com.apple.Safari") == [.fullscreen])
        #expect(WindowClassifier.buttonsNeedingEnabledState(bundleId: "com.mitchellh.ghostty") == [.fullscreen, .close])
        #expect(WindowClassifier.buttonsNeedingEnabledState(bundleId: "app.zen-browser.zen") == [.fullscreen, .minimize])
    }

    @Test func notOnScreenChromeWindowIsAPopupUntilReclassified() {
        let chrome = AppTraits(bundleId: "com.google.Chrome", activationPolicy: .regular)
        var dump = AXWindowDump(
            windowID: 1, subrole: "AXStandardWindow", title: "", closeButton: .init(isEnabled: true),
            fullscreenButton: .init(isEnabled: true), zoomButton: .init(isEnabled: true),
            minimizeButton: .init(isEnabled: true), windowLevel: nil
        )
        #expect(WindowClassifier.classify(dump, app: chrome) == .popup)
        dump.windowLevel = 0
        #expect(WindowClassifier.classify(dump, app: chrome) == .window)
    }

    // MARK: - Corpus loading

    private static func loadCorpus() -> [CorpusEntry] {
        guard let root = Bundle.module.url(forResource: "axDumps", withExtension: nil, subdirectory: "Fixtures") else {
            Issue.record("axDumps fixtures missing")
            return []
        }
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "json5" }
            .sorted { $0.path < $1.path } ?? []
        return files.map { file in
            let raw = try! JSONSerialization.jsonObject(with: Data(contentsOf: file), options: [.json5Allowed]) as! [String: Any]
            return CorpusEntry(
                name: file.path.replacingOccurrences(of: root.path + "/", with: ""),
                dump: dump(from: raw),
                app: AppTraits(
                    bundleId: raw["Aero.App.appBundleId"] as? String,
                    activationPolicy: AppActivationPolicy(rawValue: raw["Aero.App.nsApp.activationPolicy"] as! String)!
                ),
                expectedKind: WindowKind(rawValue: raw["Aero.AxUiElementWindowType"] as! String)!,
                expectedIsDialog: raw["Aero.AxUiElementWindowType_isDialogHeuristic"] as! Bool
            )
        }
    }

    private static func dump(from raw: [String: Any]) -> AXWindowDump {
        let app = raw["Aero.AXApp"] as? [String: Any] ?? [:]
        return AXWindowDump(
            windowID: windowID(raw["Aero.axWindowId"]),
            subrole: raw["AXSubrole"] as? String,
            title: raw["AXTitle"] as? String,
            identifier: raw["AXIdentifier"] as? String,
            isFocused: bool(raw["AXFocused"]),
            isMain: bool(raw["AXMain"]),
            closeButton: button(raw["AXCloseButton"]),
            fullscreenButton: button(raw["AXFullScreenButton"]),
            zoomButton: button(raw["AXZoomButton"]),
            minimizeButton: button(raw["AXMinimizeButton"]),
            appFocusedWindowID: elementWindowID(app["AXFocusedWindow"]),
            windowLevel: windowLevel(raw["Aero.windowLevel"])
        )
    }

    private static func bool(_ value: Any?) -> Bool? {
        (value as? NSNumber).map(\.boolValue)
    }

    /// A button is either a nested dump (dict) or a reference string to another element; null/absent = no button.
    private static func button(_ value: Any?) -> AXWindowDump.Button? {
        switch value {
            case let dict as [String: Any]: AXWindowDump.Button(isEnabled: bool(dict["AXEnabled"]))
            case is String: AXWindowDump.Button(isEnabled: nil)
            default: nil
        }
    }

    private static func windowID(_ value: Any?) -> UInt32? {
        switch value {
            case let number as NSNumber: UInt32(exactly: number.int64Value)
            case let string as String: UInt32(string)
            default: nil
        }
    }

    /// Element references look like `AXUIElement(AxWindowId=197, title="…", …)`.
    private static func elementWindowID(_ value: Any?) -> UInt32? {
        switch value {
            case let dict as [String: Any]: return windowID(dict["Aero.axWindowId"])
            case let string as String:
                let prefix = "AXUIElement(AxWindowId="
                guard string.hasPrefix(prefix), let comma = string.firstIndex(of: ",") else { return nil }
                return UInt32(string[string.index(string.startIndex, offsetBy: prefix.count) ..< comma])
            default: return nil
        }
    }

    private static func windowLevel(_ value: Any?) -> Int? {
        switch value {
            case "normalWindow" as String: 0
            case "alwaysOnTopWindow" as String: 3
            case let number as NSNumber: number.intValue
            default: nil
        }
    }
}
