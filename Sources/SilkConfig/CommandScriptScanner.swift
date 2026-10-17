import Foundation

/// Just enough of AeroSpace's shell syntax for the two config-level checks that need to look inside command
/// scripts: `config-version = 1` persistent-workspace inference and the `split` + flatten-normalization error.
/// Full parsing and validation of commands is SilkCore's job.
enum CommandScriptScanner {
    /// Splits a script into commands (separated by `;`, `|`, `||`, `&&` and parentheses) of shell words,
    /// honoring single quotes, double quotes and backslash escapes.
    static func commands(in script: String) -> [[String]] {
        var commands: [[String]] = []
        var words: [String] = []
        var word = ""
        var isInWord = false
        var quote: Character?
        var isEscaped = false

        func endWord() {
            if isInWord { words.append(word) }
            word = ""
            isInWord = false
        }
        func endCommand() {
            endWord()
            if !words.isEmpty { commands.append(words) }
            words = []
        }

        for char in script {
            if isEscaped {
                word.append(char)
                isEscaped = false
            } else if let open = quote {
                if char == open {
                    quote = nil
                } else if char == "\\", open == "\"" {
                    isEscaped = true
                } else {
                    word.append(char)
                }
            } else {
                switch char {
                    case "'", "\"":
                        quote = char
                        isInWord = true
                    case "\\":
                        isEscaped = true
                        isInWord = true
                    case ";", "|", "&", "(", ")":
                        endCommand()
                    case _ where char.isWhitespace:
                        endWord()
                    default:
                        word.append(char)
                        isInWord = true
                }
            }
        }
        endCommand()
        return commands
    }

    /// The workspace named by a `workspace <name>` or `move-node-to-workspace <name>` command;
    /// nil for relative targets (`next`, `prev`) and other commands.
    static func workspaceName(in command: [String]) -> String? {
        guard let name = command.first, name == "workspace" || name == "move-node-to-workspace" else { return nil }
        var index = 1
        var sawDoubleDash = false
        while index < command.count {
            let arg = command[index]
            if !sawDoubleDash {
                switch arg {
                    case "--":
                        sawDoubleDash = true
                        index += 1
                        continue
                    case "--window-id":
                        index += 2
                        continue
                    case "next", "prev":
                        return nil
                    case _ where arg.hasPrefix("--"):
                        index += 1
                        continue
                    default: break
                }
            }
            return arg
        }
        return nil
    }
}
