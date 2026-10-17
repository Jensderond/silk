// Root = Seq? EndOfInput
// Seq  = Or ((";" | "\n")+ Or?)*
// Or   = And ("||" And)*
// And  = Pipe ("&&" Pipe)*
// Pipe = "(" Seq ")" | Cmd ("|" Cmd)*
// Cmd  = Word+

/// AeroSpace's recursive-descent shell parser. Produces commands as word lists.
enum ShellParser {
    static func parse(_ source: String) -> Result<Shell<[String]>, ParseError> {
        ShellLexer.tokens(source).flatMap(parse)
    }

    static func parse(_ tokens: [ShellToken]) -> Result<Shell<[String]>, ParseError> {
        do throws(ParseError) {
            if tokens.count == 1 && tokens[0].payload == .end { return .success(.empty) }
            var index = 0
            let result = try parseSeq(&index, tokens)
            let token = tokens[index]
            if token.payload != .end {
                throw ParseError("\(token.location): Unexpected token \(token.payload.description.singleQuoted)")
            }
            return .success(result)
        } catch {
            return .failure(error)
        }
    }

    private static func parseSeq(_ index: inout Int, _ tokens: [ShellToken]) throws(ParseError) -> Shell<[String]> {
        var elements = [try parseOr(&index, tokens)]
        while tokens[index].payload == .semicolon || tokens[index].payload == .newline {
            var sawSemicolon = false
            while tokens[index].payload == .semicolon || tokens[index].payload == .newline {
                sawSemicolon = sawSemicolon || tokens[index].payload == .semicolon
                index += 1
            }
            if canStartOr(tokens[index].payload) {
                if !sawSemicolon {
                    throw ParseError("\(tokens[index].location): Please use explicit semicolon in place of a newline")
                }
                elements.append(try parseOr(&index, tokens))
            }
        }
        return .compound(elements, Shell.seq)
    }

    private static func canStartOr(_ payload: ShellToken.Payload) -> Bool {
        switch payload {
            case .word, .lParen: true
            case .end, .and, .or, .pipe, .rParen, .semicolon, .newline: false
        }
    }

    private static func parseOr(_ index: inout Int, _ tokens: [ShellToken]) throws(ParseError) -> Shell<[String]> {
        try binaryOperationLoop(.or, parseAnd, Shell.or, &index, tokens)
    }

    private static func parseAnd(_ index: inout Int, _ tokens: [ShellToken]) throws(ParseError) -> Shell<[String]> {
        try binaryOperationLoop(.and, parsePipe, Shell.and, &index, tokens)
    }

    private static func parsePipe(_ index: inout Int, _ tokens: [ShellToken]) throws(ParseError) -> Shell<[String]> {
        if tokens[index].payload == .lParen {
            index += 1
            let result = try parseSeq(&index, tokens)
            if tokens[index].payload != .rParen {
                throw ParseError("\(tokens[index].location): Expected ')'. Got: \(tokens[index].payload.description.singleQuoted)")
            }
            index += 1
            return result
        }
        return try binaryOperationLoop(.pipe, parseCmd, Shell.pipe, &index, tokens)
    }

    private static func parseCmd(_ index: inout Int, _ tokens: [ShellToken]) throws(ParseError) -> Shell<[String]> {
        var words: [String] = []
        while let token = tokens.element(at: index) {
            if case .word(let word) = token.payload {
                words.append(word)
                index += 1
            } else if words.isEmpty {
                throw ParseError("\(token.location): Expected at least one word. Got: \(token.payload)")
            } else {
                break
            }
        }
        return .cmd(words)
    }

    private static func binaryOperationLoop(
        _ op: ShellToken.Payload,
        _ descend: (inout Int, [ShellToken]) throws(ParseError) -> Shell<[String]>,
        _ constructor: ([Shell<[String]>]) -> Shell<[String]>,
        _ index: inout Int,
        _ tokens: [ShellToken]
    ) throws(ParseError) -> Shell<[String]> {
        var elements = [try descend(&index, tokens)]
        while let token = tokens.element(at: index), token.payload == op {
            index += 1
            elements.append(try descend(&index, tokens))
        }
        return .compound(elements, constructor)
    }
}
