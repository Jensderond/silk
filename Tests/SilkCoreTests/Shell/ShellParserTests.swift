import Testing
@testable import SilkCore

// Ported from AeroSpace's ShellParserTest.

extension Shell where T == [String] {
    static func or(_ a: Self, _ b: Self) -> Self { .or([a, b]) }
    static func and(_ a: Self, _ b: Self) -> Self { .and([a, b]) }
    static func pipe(_ a: Self, _ b: Self) -> Self { .pipe([a, b]) }
    static func seq(_ a: Self, _ b: Self) -> Self { .seq([a, b]) }
    static func cmd(_ a: String, _ b: String) -> Self { .cmd([a, b]) }
    static func cmd(_ a: String) -> Self { .cmd([a]) }
}

extension Shell: ExpressibleByUnicodeScalarLiteral where T == [String] {}
extension Shell: ExpressibleByExtendedGraphemeClusterLiteral where T == [String] {}
extension Shell: ExpressibleByStringLiteral where T == [String] {
    public init(stringLiteral value: String) { self = .cmd([value]) }
}

@Suite struct ShellParserTests {
    @Test func parser() {
        #expect(ShellParser.parse("echo foo && bar") == .success(.and(.cmd("echo", "foo"), "bar")))
        #expect(ShellParser.parse("foo && bar || baz") == .success(.or(.and("foo", "bar"), "baz")))
        #expect(ShellParser.parse("foo || bar && baz") == .success(.or("foo", .and("bar", "baz"))))
        #expect(ShellParser.parse("echo '' \"\"") == .success(.cmd(["echo", "", ""])))

        let a = """
            foo ||
                bar
            """
        #expect(ShellParser.parse(a) == .failure(ParseError("Line 1 Column 7: Expected at least one word. Got: \n")))
        let b = """
            foo
                || bar
            """
        #expect(ShellParser.parse(b) == .failure(ParseError("Line 1 Column 4: Please escape newline with backslash character.")))
        let c = """
            foo || \\
                bar || \\ # comment
                baz \\
                || duh \\ # comment
                || qux
            """
        #expect(ShellParser.parse(c) == .success(.or(["foo", "bar", "baz", "duh", "qux"])))
    }

    @Test func parserEmpty() {
        #expect(ShellParser.parse("") == .success(.empty))
        #expect(ShellParser.parse("   ") == .success(.empty))
        #expect(ShellParser.parse("\t") == .success(.empty))
        #expect(ShellParser.parse("# only a comment") == .success(.empty))
    }

    @Test func parserSingleCommand() {
        #expect(ShellParser.parse("foo") == .success("foo"))
        #expect(ShellParser.parse("foo bar") == .success(.cmd("foo", "bar")))
        #expect(ShellParser.parse("foo bar baz") == .success(.cmd(["foo", "bar", "baz"])))
    }

    @Test func parserPipe() {
        #expect(ShellParser.parse("foo | bar") == .success(.pipe("foo", "bar")))
        #expect(ShellParser.parse("a | b | c") == .success(.pipe(["a", "b", "c"])))
        #expect(ShellParser.parse("a b | c d") == .success(.pipe(.cmd("a", "b"), .cmd("c", "d"))))
    }

    @Test func parserAndChain() {
        #expect(ShellParser.parse("a && b && c") == .success(.and(["a", "b", "c"])))
    }

    @Test func parserOrChain() {
        #expect(ShellParser.parse("a || b || c") == .success(.or(["a", "b", "c"])))
    }

    @Test func parserPrecedence() {
        #expect(ShellParser.parse("a | b && c") == .success(.and(.pipe("a", "b"), "c")))
        #expect(ShellParser.parse("a && b | c") == .success(.and("a", .pipe("b", "c"))))
        #expect(ShellParser.parse("a | b || c") == .success(.or(.pipe("a", "b"), "c")))
        #expect(ShellParser.parse("a || b | c") == .success(.or("a", .pipe("b", "c"))))
        #expect(ShellParser.parse("a | b && c || d") == .success(.or(.and(.pipe("a", "b"), "c"), "d")))
    }

    @Test func parserSemicolon() {
        #expect(ShellParser.parse("foo; bar") == .success(.seq("foo", "bar")))
        #expect(ShellParser.parse("a;b") == .success(.seq("a", "b")))
        #expect(ShellParser.parse("a;;b") == .success(.seq("a", "b")))
        #expect(ShellParser.parse("a; b; c") == .success(.seq(["a", "b", "c"])))
        #expect(ShellParser.parse("a && b; c || d") == .success(.seq(.and("a", "b"), .or("c", "d"))))
        #expect(ShellParser.parse("a | b; c | d") == .success(.seq(.pipe("a", "b"), .pipe("c", "d"))))
    }

    @Test func parserParens() {
        #expect(ShellParser.parse("(foo)") == .success("foo"))
        #expect(ShellParser.parse("(foo bar)") == .success(.cmd("foo", "bar")))
        #expect(ShellParser.parse("((foo))") == .success("foo"))
        #expect(ShellParser.parse("(a; b)") == .success(.seq("a", "b")))
        #expect(ShellParser.parse("(a && b) || c") == .success(.or(.and("a", "b"), "c")))
        #expect(ShellParser.parse("a && (b || c)") == .success(.and("a", .or("b", "c"))))
        #expect(ShellParser.parse("(a || b) && (c || d)") == .success(.and(.or("a", "b"), .or("c", "d"))))
    }

    @Test func parserFailNewlineWithoutSemicolon() {
        #expect(ShellParser.parse("foo\nbar") == .failure(ParseError("Line 2 Column 1: Please use explicit semicolon in place of a newline")))
        #expect(ShellParser.parse("foo bar;\nbaz") == .success(.seq(.cmd("foo", "bar"), "baz")))
    }

    @Test func parserTrailingOperator() {
        #expect(ShellParser.parse("foo;") == .success(.cmd("foo")))
        #expect(ShellParser.parse("foo\n\n") == .success(.cmd("foo")))
        #expect(ShellParser.parse("foo\n\n;\n") == .success(.cmd("foo")))

        #expect(ShellParser.parse("foo &&") == .failure(ParseError("Line 1 Column 7: Expected at least one word. Got: End of input")))
        #expect(ShellParser.parse("foo ||") == .failure(ParseError("Line 1 Column 7: Expected at least one word. Got: End of input")))
        #expect(ShellParser.parse("foo |") == .failure(ParseError("Line 1 Column 6: Expected at least one word. Got: End of input")))
    }

    @Test func parserFailLeadingOperator() {
        #expect(ShellParser.parse("&& foo") == .failure(ParseError("Line 1 Column 1: Expected at least one word. Got: &&")))
        #expect(ShellParser.parse("|| foo") == .failure(ParseError("Line 1 Column 1: Expected at least one word. Got: ||")))
        #expect(ShellParser.parse("| foo") == .failure(ParseError("Line 1 Column 1: Expected at least one word. Got: |")))
        #expect(ShellParser.parse(";") == .failure(ParseError("Line 1 Column 1: Expected at least one word. Got: ;")))
    }

    @Test func parserFailParens() {
        #expect(ShellParser.parse("()") == .failure(ParseError("Line 1 Column 2: Expected at least one word. Got: )")))
        #expect(ShellParser.parse("(foo") == .failure(ParseError("Line 1 Column 5: Expected ')'. Got: 'End of input'")))
        #expect(ShellParser.parse("foo)") == .failure(ParseError("Line 1 Column 4: Unexpected token ')'")))
        // Per the grammar, a parenthesized group is a Pipe-level atom and cannot itself be piped.
        #expect(ShellParser.parse("(foo) | bar") == .failure(ParseError("Line 1 Column 7: Unexpected token '|'")))
    }

    @Test func buildDescription() {
        func render(_ shell: Shell<[String]>) -> String { shell.description { $0.joined(separator: " ") } }

        #expect(render(.or(.and("a", "b"), "c")) == "a && b || c")
        #expect(render(.seq(.or("a", "b"), .and("c", "d"))) == "a || b; c && d")
        #expect(render(.and(.pipe("a", "b"), "c")) == "a | b && c")

        #expect(render(.and(.or("a", "b"), "c")) == "(a || b) && c")
        #expect(render(.and("a", .or("b", "c"))) == "a && (b || c)")
        #expect(render(.pipe(.seq("a", "b"), "c")) == "(a; b) | c")
        #expect(render(.or(.seq("a", "b"), "c")) == "(a; b) || c")
        #expect(render(.and(.or("a", "b"), .or("c", "d"))) == "(a || b) && (c || d)")

        #expect(render("foo") == "foo")
        #expect(render(.and(["a", "b", "c"])) == "a && b && c")
        #expect(render(.empty) == "")
    }
}
