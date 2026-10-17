import Foundation

/// A compiled case-insensitive regular expression used for substring matches (window titles, app names,
/// monitor names, `test ~=`).
struct CaseInsensitiveRegex {
    let pattern: String
    private let regex: NSRegularExpression

    init(_ pattern: String) throws(ParseError) {
        do {
            regex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        } catch {
            throw ParseError("Can't parse \(pattern.singleQuoted) regex: \(error.localizedDescription)")
        }
        self.pattern = pattern
    }

    func matches(_ string: String) -> Bool {
        regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)) != nil
    }
}

/// Patterns come from the config and are matched many times; compile each once.
final class RegexCache {
    private var compiled: [String: CaseInsensitiveRegex?] = [:]

    func regex(_ pattern: String) -> CaseInsensitiveRegex? {
        if let cached = compiled[pattern] { return cached }
        let regex = try? CaseInsensitiveRegex(pattern)
        compiled[pattern] = regex
        return regex
    }

    func matches(_ string: String, pattern: String) -> Bool {
        regex(pattern)?.matches(string) ?? false
    }
}
