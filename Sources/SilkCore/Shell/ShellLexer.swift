/// A position in a shell script, 1-based.
struct SourceLocation: Equatable, CustomStringConvertible {
    var line: Int
    var column: Int

    var description: String { "Line \(line) Column \(column)" }
}

struct ShellToken: Equatable {
    enum Payload: Equatable, CustomStringConvertible {
        case end
        case word(String)
        case and // &&
        case or // ||
        case pipe // |
        case lParen // (
        case rParen // )
        case semicolon // ;
        case newline // \n

        var description: String {
            switch self {
                case .end: "End of input"
                case .word(let word): word
                case .and: "&&"
                case .or: "||"
                case .pipe: "|"
                case .lParen: "("
                case .rParen: ")"
                case .semicolon: ";"
                case .newline: "\n"
            }
        }
    }

    let location: SourceLocation
    let payload: Payload
}

/// AeroSpace's shell lexer: bare and quoted words, `&& || | ; ( )`, newlines, `#` comments and
/// backslash line continuations.
enum ShellLexer {
    private enum State {
        case comment
        case quotedWord(quote: Character)
        case backslash
        case bareWord
        case skipWhitespaces
        case rightAfterQuotedWord
    }

    private enum WordKind { case bare, quoted }

    private static let reservedCharacters: Set<Character> = ["(", ")", "$", "~", "&", "?", "*", "!", "\\", "|", "<", ">", "`", "'", "\"", "#", "\n"]

    static func tokens(_ source: String) -> Result<[ShellToken], ParseError> {
        do throws(ParseError) {
            return .success(try lex(source))
        } catch {
            return .failure(error)
        }
    }

    private static func lex(_ source: String) throws(ParseError) -> [ShellToken] {
        var result: [ShellToken] = []
        var word = ""
        var state = State.skipWhitespaces
        var wordLocation = SourceLocation(line: 1, column: 1)

        var chars: [(value: Character, location: SourceLocation)] = []
        var location = SourceLocation(line: 1, column: 1)
        for char in source + " " { // Synthetic trailing space flushes the last word
            chars.append((char, location))
            location.column += 1
            if char == "\n" {
                location.line += 1
                location.column = 1
            }
        }

        func flushWord(_ kind: WordKind) throws(ParseError) {
            if kind == .bare, word != "~=", let reserved = word.first(where: { reservedCharacters.contains($0) }) {
                throw ParseError("\(wordLocation): Bare word '\(word)' contains reserved character: \(reserved). Please quote the bare word if you want to use the character.")
            }
            if kind == .quoted || !word.isEmpty {
                result.append(ShellToken(location: wordLocation, payload: .word(word)))
                word = ""
            }
            state = .skipWhitespaces
        }

        var index = 0
        func next() -> Character? { chars.element(at: index)?.value }
        while let char = chars.element(at: index) {
            index += 1
            let value = char.value
            switch state {
                case .comment:
                    if value == "\n" {
                        result.append(ShellToken(location: char.location, payload: .newline))
                        state = .skipWhitespaces
                    }
                    continue
                case .quotedWord(let quote):
                    if value == quote {
                        try flushWord(.quoted)
                        state = .rightAfterQuotedWord
                    } else {
                        word.append(value)
                    }
                    continue
                case .backslash:
                    if value == "#" {
                        while let following = next(), following != "\n" { index += 1 } // Skip the comment
                    } else if value == "\n" {
                        state = .skipWhitespaces
                    } else if !value.isWhitespace {
                        throw ParseError("\(char.location): backslash can be followed only by whitespaces, newlines and comments, but it is followed by \(String(value).singleQuoted).")
                    }
                    continue
                case .skipWhitespaces, .bareWord, .rightAfterQuotedWord:
                    break
            }

            if value == "\n" {
                try flushWord(.bare)
                result.append(ShellToken(location: char.location, payload: .newline))
            } else if case .rightAfterQuotedWord = state, value.isWhitespace {
                state = .skipWhitespaces
            } else if value == "&" && next() == "&" {
                try flushWord(.bare)
                result.append(ShellToken(location: char.location, payload: .and))
                index += 1
            } else if value == "|" && next() == "|" {
                try flushWord(.bare)
                result.append(ShellToken(location: char.location, payload: .or))
                index += 1
            } else if value == "|" {
                try flushWord(.bare)
                result.append(ShellToken(location: char.location, payload: .pipe))
            } else if value == "\\" && next() == "#" {
                throw ParseError("\(char.location): Please put a space between backslash and a comment start")
            } else if value == "\\" {
                try flushWord(.bare)
                state = .backslash
            } else if value == "#" {
                try flushWord(.bare)
                state = .comment
            } else if value == ";" {
                try flushWord(.bare)
                result.append(ShellToken(location: char.location, payload: .semicolon))
            } else if value == "(" {
                try flushWord(.bare)
                result.append(ShellToken(location: char.location, payload: .lParen))
            } else if value == ")" {
                try flushWord(.bare)
                result.append(ShellToken(location: char.location, payload: .rParen))
            } else if case .skipWhitespaces = state, value == "'" || value == "\"" {
                state = .quotedWord(quote: value)
                wordLocation = char.location
            } else if value == "'" || value == "\"" {
                throw ParseError("\(char.location): Please put a space in front of the quote character.")
            } else if case .rightAfterQuotedWord = state {
                throw ParseError("\(char.location): Please put a space after closing quote.")
            } else if case .skipWhitespaces = state {
                if !value.isWhitespace {
                    state = .bareWord
                    wordLocation = char.location
                    word.append(value)
                }
            } else if value.isWhitespace { // .bareWord
                try flushWord(.bare)
            } else {
                word.append(value)
            }
        }

        let endLocation = chars[chars.count - 1].location
        if case .quotedWord(let quote) = state {
            throw ParseError("\(endLocation): Last quote \(quote) isn't closed.")
        }
        result.append(ShellToken(location: endLocation, payload: .end))
        let binaryOperators: [ShellToken.Payload] = [.and, .or, .pipe]
        for (index, token) in result.enumerated() {
            if token.payload == .newline, let following = result.element(at: index + 1), binaryOperators.contains(following.payload) {
                throw ParseError("\(token.location): Please escape newline with backslash character.")
            }
        }
        return result
    }
}
