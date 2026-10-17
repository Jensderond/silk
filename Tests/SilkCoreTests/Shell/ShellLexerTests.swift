import Testing
@testable import SilkCore

// Ported from AeroSpace's ShellLexerTest.

private func lex(_ source: String) -> Result<[ShellToken], ParseError> { ShellLexer.tokens(source) }

private extension ShellToken {
    static func word(l: Int, c: Int, _ word: String) -> ShellToken { ShellToken(location: SourceLocation(line: l, column: c), payload: .word(word)) }
    static func and(l: Int, c: Int) -> ShellToken { ShellToken(location: SourceLocation(line: l, column: c), payload: .and) }
    static func or(l: Int, c: Int) -> ShellToken { ShellToken(location: SourceLocation(line: l, column: c), payload: .or) }
    static func pipe(l: Int, c: Int) -> ShellToken { ShellToken(location: SourceLocation(line: l, column: c), payload: .pipe) }
    static func lParen(l: Int, c: Int) -> ShellToken { ShellToken(location: SourceLocation(line: l, column: c), payload: .lParen) }
    static func rParen(l: Int, c: Int) -> ShellToken { ShellToken(location: SourceLocation(line: l, column: c), payload: .rParen) }
    static func semicolon(l: Int, c: Int) -> ShellToken { ShellToken(location: SourceLocation(line: l, column: c), payload: .semicolon) }
    static func end(l: Int, c: Int) -> ShellToken { ShellToken(location: SourceLocation(line: l, column: c), payload: .end) }
    static func newline(l: Int, c: Int) -> ShellToken { ShellToken(location: SourceLocation(line: l, column: c), payload: .newline) }
}

@Suite struct ShellLexerTests {
    @Test func lexer() {
        #expect(lex("echo foo") == .success([.word(l: 1, c: 1, "echo"), .word(l: 1, c: 6, "foo"), .end(l: 1, c: 9)]))
        #expect(lex("echo  foo") == .success([.word(l: 1, c: 1, "echo"), .word(l: 1, c: 7, "foo"), .end(l: 1, c: 10)]))
        #expect(lex("echo 'foo' &&") == .success([.word(l: 1, c: 1, "echo"), .word(l: 1, c: 6, "foo"), .and(l: 1, c: 12), .end(l: 1, c: 14)]))
        #expect(lex("echo 'foo' \\ \n&&") == .success([.word(l: 1, c: 1, "echo"), .word(l: 1, c: 6, "foo"), .and(l: 2, c: 1), .end(l: 2, c: 3)]))
        #expect(lex("echo 'foo'\n &&") == .failure(ParseError("Line 1 Column 11: Please escape newline with backslash character.")))
        #expect(lex("echo 'foo' \n &&") == .failure(ParseError("Line 1 Column 12: Please escape newline with backslash character.")))

        #expect(lex("echo ''") == .success([.word(l: 1, c: 1, "echo"), .word(l: 1, c: 6, ""), .end(l: 1, c: 8)]))
    }

    @Test func lexerEmpty() {
        #expect(lex("") == .success([.end(l: 1, c: 1)]))
        #expect(lex("   ") == .success([.end(l: 1, c: 4)]))
        #expect(lex("\t") == .success([.end(l: 1, c: 2)]))
    }

    @Test func lexerLeadingWhitespace() {
        #expect(lex("  echo") == .success([.word(l: 1, c: 3, "echo"), .end(l: 1, c: 7)]))
        #expect(lex("\techo\tfoo") == .success([.word(l: 1, c: 2, "echo"), .word(l: 1, c: 7, "foo"), .end(l: 1, c: 10)]))
    }

    @Test func lexerComments() {
        #expect(lex("# hello") == .success([.end(l: 1, c: 8)]))
        #expect(lex("echo # comment") == .success([.word(l: 1, c: 1, "echo"), .end(l: 1, c: 15)]))
        #expect(lex("echo#nospace") == .success([.word(l: 1, c: 1, "echo"), .end(l: 1, c: 13)]))
        #expect(lex("echo # hi\nfoo") == .success([.word(l: 1, c: 1, "echo"), .newline(l: 1, c: 10), .word(l: 2, c: 1, "foo"), .end(l: 2, c: 4)]))
    }

    @Test func lexerSingleQuotes() {
        #expect(lex("echo 'hello world'") == .success([.word(l: 1, c: 1, "echo"), .word(l: 1, c: 6, "hello world"), .end(l: 1, c: 19)]))
        #expect(lex("'foo'") == .success([.word(l: 1, c: 1, "foo"), .end(l: 1, c: 6)]))
        #expect(lex("echo 'a\"b'") == .success([.word(l: 1, c: 1, "echo"), .word(l: 1, c: 6, "a\"b"), .end(l: 1, c: 11)]))
    }

    @Test func lexerDoubleQuotes() {
        #expect(lex("echo \"hello world\"") == .success([.word(l: 1, c: 1, "echo"), .word(l: 1, c: 6, "hello world"), .end(l: 1, c: 19)]))
        #expect(lex("\"foo\"") == .success([.word(l: 1, c: 1, "foo"), .end(l: 1, c: 6)]))
        #expect(lex("echo \"it's\"") == .success([.word(l: 1, c: 1, "echo"), .word(l: 1, c: 6, "it's"), .end(l: 1, c: 12)]))
    }

    @Test func lexerQuotedNewline() {
        #expect(lex("echo 'foo\nbar'") == .success([.word(l: 1, c: 1, "echo"), .word(l: 1, c: 6, "foo\nbar"), .end(l: 2, c: 5)]))
    }

    @Test func lexerPipeAndOr() {
        #expect(lex("echo foo | bar") == .success([.word(l: 1, c: 1, "echo"), .word(l: 1, c: 6, "foo"), .pipe(l: 1, c: 10), .word(l: 1, c: 12, "bar"), .end(l: 1, c: 15)]))
        #expect(lex("echo foo || bar") == .success([.word(l: 1, c: 1, "echo"), .word(l: 1, c: 6, "foo"), .or(l: 1, c: 10), .word(l: 1, c: 13, "bar"), .end(l: 1, c: 16)]))
        #expect(lex("a|b") == .success([.word(l: 1, c: 1, "a"), .pipe(l: 1, c: 2), .word(l: 1, c: 3, "b"), .end(l: 1, c: 4)]))
        #expect(lex("a||b") == .success([.word(l: 1, c: 1, "a"), .or(l: 1, c: 2), .word(l: 1, c: 4, "b"), .end(l: 1, c: 5)]))
        #expect(lex("a&&b") == .success([.word(l: 1, c: 1, "a"), .and(l: 1, c: 2), .word(l: 1, c: 4, "b"), .end(l: 1, c: 5)]))
    }

    @Test func lexerSemicolon() {
        #expect(lex("echo a;b") == .success([.word(l: 1, c: 1, "echo"), .word(l: 1, c: 6, "a"), .semicolon(l: 1, c: 7), .word(l: 1, c: 8, "b"), .end(l: 1, c: 9)]))
        #expect(lex("echo foo; echo bar") == .success([.word(l: 1, c: 1, "echo"), .word(l: 1, c: 6, "foo"), .semicolon(l: 1, c: 9), .word(l: 1, c: 11, "echo"), .word(l: 1, c: 16, "bar"), .end(l: 1, c: 19)]))
    }

    @Test func lexerParens() {
        #expect(lex("(echo)") == .success([.lParen(l: 1, c: 1), .word(l: 1, c: 2, "echo"), .rParen(l: 1, c: 6), .end(l: 1, c: 7)]))
        #expect(lex("( echo foo )") == .success([.lParen(l: 1, c: 1), .word(l: 1, c: 3, "echo"), .word(l: 1, c: 8, "foo"), .rParen(l: 1, c: 12), .end(l: 1, c: 13)]))
    }

    @Test func lexerBackslashLineContinuation() {
        #expect(lex("echo \\\n foo") == .success([.word(l: 1, c: 1, "echo"), .word(l: 2, c: 2, "foo"), .end(l: 2, c: 5)]))
        #expect(lex("echo \\\nfoo") == .success([.word(l: 1, c: 1, "echo"), .word(l: 2, c: 1, "foo"), .end(l: 2, c: 4)]))
        #expect(lex("echo \\ \nfoo") == .success([.word(l: 1, c: 1, "echo"), .word(l: 2, c: 1, "foo"), .end(l: 2, c: 4)]))
    }

    @Test func lexerMultipleNewlines() {
        #expect(lex("\n\n\n") == .success([.newline(l: 1, c: 1), .newline(l: 2, c: 1), .newline(l: 3, c: 1), .end(l: 4, c: 1)]))
        #expect(lex("echo foo\necho bar") == .success([.word(l: 1, c: 1, "echo"), .word(l: 1, c: 6, "foo"), .newline(l: 1, c: 9), .word(l: 2, c: 1, "echo"), .word(l: 2, c: 6, "bar"), .end(l: 2, c: 9)]))
        #expect(lex("echo foo\n") == .success([.word(l: 1, c: 1, "echo"), .word(l: 1, c: 6, "foo"), .newline(l: 1, c: 9), .end(l: 2, c: 1)]))
    }

    @Test func lexerFailUnclosedQuote() {
        #expect(lex("echo 'foo") == .failure(ParseError("Line 1 Column 10: Last quote ' isn't closed.")))
        #expect(lex("echo \"foo") == .failure(ParseError("Line 1 Column 10: Last quote \" isn't closed.")))
    }

    @Test func lexerFailQuoteInMiddleOfWord() {
        #expect(lex("echo foo'bar'") == .failure(ParseError("Line 1 Column 9: Please put a space in front of the quote character.")))
    }

    @Test func lexerFailMissingSpaceAfterClosingQuote() {
        #expect(lex("echo 'foo'bar") == .failure(ParseError("Line 1 Column 11: Please put a space after closing quote.")))
    }

    @Test func lexerFailReservedChar() {
        #expect(lex("echo $foo") == .failure(ParseError("Line 1 Column 6: Bare word '$foo' contains reserved character: $. Please quote the bare word if you want to use the character.")))
        #expect(lex("echo *") == .failure(ParseError("Line 1 Column 6: Bare word '*' contains reserved character: *. Please quote the bare word if you want to use the character.")))
        #expect(lex("echo ~") == .failure(ParseError("Line 1 Column 6: Bare word '~' contains reserved character: ~. Please quote the bare word if you want to use the character.")))
    }

    @Test func lexerFailBackslashFollowedByNonWhitespace() {
        #expect(lex("echo \\a") == .failure(ParseError("Line 1 Column 7: backslash can be followed only by whitespaces, newlines and comments, but it is followed by 'a'.")))
    }

    @Test func lexerFailBackslashFollowedByComment() {
        #expect(lex("echo \\#foo") == .failure(ParseError("Line 1 Column 6: Please put a space between backslash and a comment start")))
    }
}
