import Foundation

/// What the Settings window edits. Stored by the app, apart from the config file, which stays hand-written.
public struct AppSettings: Codable, Equatable, Sendable {
    /// One row of "Rules for where apps go".
    public struct Rule: Codable, Equatable, Identifiable, Sendable {
        public enum Kind: String, Codable, Sendable, CaseIterable {
            /// Move every window of an app to a workspace when it opens.
            case sendToWorkspace
            /// Don't tile windows whose title contains a text.
            case leaveAlone
        }

        public var id = UUID()
        public var kind: Kind
        /// `sendToWorkspace`: the app's bundle id, and its name for display.
        public var appId = ""
        public var appName = ""
        public var workspace = ""
        /// `leaveAlone`: text the window title contains (case-insensitive).
        public var title = ""

        public init(kind: Kind) { self.kind = kind }

        /// The `on-window-detected` rule this row stands for; nil while the row is incomplete.
        public var windowDetectedRule: WindowDetectedRule? {
            var rule = WindowDetectedRule()
            switch kind {
                case .sendToWorkspace:
                    let workspace = workspace.trimmingCharacters(in: .whitespaces)
                    guard !appId.isEmpty, !workspace.isEmpty, !workspace.contains(where: \.isWhitespace) else { return nil }
                    rule.matcher.appId = appId
                    rule.run = CommandScripts(["move-node-to-workspace \(workspace)"])
                case .leaveAlone:
                    let title = title.trimmingCharacters(in: .whitespaces)
                    guard !title.isEmpty else { return nil }
                    rule.matcher.windowTitleRegexSubstring = NSRegularExpression.escapedPattern(for: title)
                    rule.run = CommandScripts(["layout floating"])
            }
            return rule
        }
    }

    /// Checked in order, before the config file's `on-window-detected`; the first match wins.
    public var rules: [Rule] = []
    /// A three-finger horizontal swipe switches to the next or previous workspace.
    public var swipeBetweenWorkspaces = false

    public init() {}

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rules = try container.decodeIfPresent([Rule].self, forKey: .rules) ?? []
        swipeBetweenWorkspaces = try container.decodeIfPresent(Bool.self, forKey: .swipeBetweenWorkspaces) ?? false
    }

    public var windowDetectedRules: [WindowDetectedRule] { rules.compactMap(\.windowDetectedRule) }
}
