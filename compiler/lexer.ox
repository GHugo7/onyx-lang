// Turns source text into tokens.
//
// The source is handled as bytes, and every position is a number of bytes
// from the start of the file: that is what the rest of the compiler, and
// the messages it prints, count in.

import "diag"

// A string literal is made of pieces: plain text, and the code between the
// braces of an interpolation (kept as the positions where it starts and ends).
enum Piece {
    Lit(string)
    Code(start: int, end: int)
}

enum Tok {
    Int(int)
    Float(float)
    Str([Piece])
    Ident(string)
    // Keywords
    Fn
    Var
    Const
    Struct
    Enum
    Match
    Interface
    If
    Else
    While
    For
    In
    Return
    Break
    Continue
    Fail
    Or
    Catch
    Fork
    Chan
    Import
    True
    False
    // Punctuation
    LParen
    RParen
    LBrace
    RBrace
    LBracket
    RBracket
    Comma
    Colon
    Semi
    Dot
    DotDot
    Arrow
    LArrow
    Eq
    EqEq
    NotEq
    Lt
    Le
    Gt
    Ge
    Plus
    Minus
    Star
    Slash
    Percent
    Amp
    Pipe
    Caret
    Tilde
    Shl
    Shr
    Bang
    AndAnd
    OrOr
    Question
    PlusEq
    MinusEq
    StarEq
    SlashEq
    Eof
}

struct Token {
    tok: Tok
    start: int
    end: int
    // True when at least one line break separates this token from the previous one.
    nl_before: bool
}

// The bytes that matter, by name.
const NEWLINE = 10
const QUOTE = 34
const BACKSLASH = 92
const OPEN_BRACE = 123
const CLOSE_BRACE = 125

fn is_digit(c: int) -> bool {
    return c >= 48 && c <= 57
}

fn is_letter(c: int) -> bool {
    // Bytes from 128 on belong to characters outside ASCII: letters with
    // accents and other alphabets may be used in names.
    return (c >= 97 && c <= 122) || (c >= 65 && c <= 90) || c == 95 || c >= 128
}

fn is_ascii_letter(c: int) -> bool {
    return (c >= 97 && c <= 122) || (c >= 65 && c <= 90)
}

// The value of a digit of a hexadecimal or binary number (99: not a digit).
fn digit_value(c: int) -> int {
    if is_digit(c) {
        return c - 48
    }
    if c >= 97 && c <= 102 {
        return c - 87
    }
    if c >= 65 && c <= 70 {
        return c - 55
    }
    return 99
}

// The text between two positions.
fn text_of(src: [int], start: int, end: int) -> string {
    return from_bytes(src.slice(start, end))
}

fn keyword(word: string) -> Tok {
    match word {
        "fn" {
            return Tok.Fn
        }
        "var" {
            return Tok.Var
        }
        "const" {
            return Tok.Const
        }
        "struct" {
            return Tok.Struct
        }
        "enum" {
            return Tok.Enum
        }
        "match" {
            return Tok.Match
        }
        "interface" {
            return Tok.Interface
        }
        "if" {
            return Tok.If
        }
        "else" {
            return Tok.Else
        }
        "while" {
            return Tok.While
        }
        "for" {
            return Tok.For
        }
        "in" {
            return Tok.In
        }
        "return" {
            return Tok.Return
        }
        "break" {
            return Tok.Break
        }
        "continue" {
            return Tok.Continue
        }
        "fail" {
            return Tok.Fail
        }
        "or" {
            return Tok.Or
        }
        "catch" {
            return Tok.Catch
        }
        "fork" {
            return Tok.Fork
        }
        "chan" {
            return Tok.Chan
        }
        "import" {
            return Tok.Import
        }
        "true" {
            return Tok.True
        }
        "false" {
            return Tok.False
        }
        else {
            return Tok.Ident(word)
        }
    }
}

// The token that the two bytes `c` and `next` make together, if any.
fn double(c: int, next: int) -> Tok! {
    var pair = chr(c) + chr(next)
    match pair {
        ".." {
            return Tok.DotDot
        }
        "->" {
            return Tok.Arrow
        }
        "<-" {
            return Tok.LArrow
        }
        "==" {
            return Tok.EqEq
        }
        "!=" {
            return Tok.NotEq
        }
        "<=" {
            return Tok.Le
        }
        ">=" {
            return Tok.Ge
        }
        "&&" {
            return Tok.AndAnd
        }
        "||" {
            return Tok.OrOr
        }
        "<<" {
            return Tok.Shl
        }
        ">>" {
            return Tok.Shr
        }
        "+=" {
            return Tok.PlusEq
        }
        "-=" {
            return Tok.MinusEq
        }
        "*=" {
            return Tok.StarEq
        }
        "/=" {
            return Tok.SlashEq
        }
        else {
            fail "not a token"
        }
    }
}

// The token that the byte `c` makes alone, if any.
fn single(c: int) -> Tok! {
    match chr(c) {
        "(" {
            return Tok.LParen
        }
        ")" {
            return Tok.RParen
        }
        "\{" {
            return Tok.LBrace
        }
        "\}" {
            return Tok.RBrace
        }
        "[" {
            return Tok.LBracket
        }
        "]" {
            return Tok.RBracket
        }
        "," {
            return Tok.Comma
        }
        ":" {
            return Tok.Colon
        }
        ";" {
            return Tok.Semi
        }
        "." {
            return Tok.Dot
        }
        "=" {
            return Tok.Eq
        }
        "<" {
            return Tok.Lt
        }
        ">" {
            return Tok.Gt
        }
        "+" {
            return Tok.Plus
        }
        "-" {
            return Tok.Minus
        }
        "*" {
            return Tok.Star
        }
        "/" {
            return Tok.Slash
        }
        "%" {
            return Tok.Percent
        }
        "&" {
            return Tok.Amp
        }
        "|" {
            return Tok.Pipe
        }
        "^" {
            return Tok.Caret
        }
        "~" {
            return Tok.Tilde
        }
        "!" {
            return Tok.Bang
        }
        "?" {
            return Tok.Question
        }
        else {
            fail "not a token"
        }
    }
}

// How many bytes the character that starts with the byte `lead` takes.
fn char_size(lead: int) -> int {
    if lead < 192 {
        return 1
    }
    if lead < 224 {
        return 2
    }
    if lead < 240 {
        return 3
    }
    return 4
}

struct Lexer {
    src: [int]
    end: int
    at: int
    report: diag.Report

    // A number: digits (with `_` to group them), an optional fraction and
    // an optional exponent.
    fn number(self) -> Tok! {
        var src = self.src
        var start = self.at
        // `0x1F` (hexadecimal) and `0b101` (binary) are whole numbers of up
        // to 64 bits, which are the bits of the int: `0xFFFFFFFFFFFFFFFF` is -1.
        if src[start] == 48 && start + 1 < self.end && (src[start + 1] == 120 || src[start + 1] == 98) {
            return self.radix_number()?
        }
        var i = start
        while i < self.end && (is_digit(src[i]) || src[i] == 95) {
            i += 1
        }
        var is_float = false
        // A fraction needs a digit after the dot, so `1..5` and `1.str()` still work.
        if i + 1 < self.end && src[i] == 46 && is_digit(src[i + 1]) {
            is_float = true
            i += 1
            while i < self.end && (is_digit(src[i]) || src[i] == 95) {
                i += 1
            }
        }
        // An exponent: `1e9`, `6.02e23`, `1.5e-7`.
        if i < self.end && (src[i] == 101 || src[i] == 69) {
            var j = i + 1
            if j < self.end && (src[j] == 43 || src[j] == 45) {
                j += 1
            }
            if j < self.end && is_digit(src[j]) {
                is_float = true
                while j < self.end && is_digit(src[j]) {
                    j += 1
                }
                i = j
            }
        }
        self.at = i
        var text = text_of(src, start, i).replace("_", "")
        if is_float {
            var value = parse_float(text) catch err {
                self.report.add("E0001", "invalid number", start, i)
                fail "syntax"
            }
            return Tok.Float(value)
        }
        var value = parse_int(text) catch err {
            var d = self.report.add("E0001", "integer literal is too large", start, i)
            d.label = "does not fit in an int"
            fail "syntax"
        }
        return Tok.Int(value)
    }

    // `0x...` or `0b...`, with `self.at` on the `0`.
    fn radix_number(self) -> Tok! {
        var src = self.src
        var start = self.at
        var radix = 2
        var bits = 1
        var label = "binary digits are 0 and 1"
        if src[start + 1] == 120 {
            radix = 16
            bits = 4
            label = "hexadecimal digits are 0-9 and a-f"
        }
        var i = start + 2
        while i < self.end && (is_digit(src[i]) || is_ascii_letter(src[i]) || src[i] == 95) {
            i += 1
        }
        self.at = i
        var digits: [int] = []
        var valid = true
        for k in start + 2..i {
            if src[k] != 95 {
                var d = digit_value(src[k])
                if d >= radix {
                    valid = false
                }
                digits.push(d)
            }
        }
        if !valid || digits.len() == 0 {
            var d = self.report.add("E0001", "invalid number", start, i)
            d.label = label
            fail "syntax"
        }
        var significant = digits.len()
        for d in digits {
            if d != 0 {
                break
            }
            significant -= 1
        }
        if significant * bits > 64 {
            var d = self.report.add("E0001", "integer literal is too large", start, i)
            d.label = "does not fit in an int"
            fail "syntax"
        }
        var value = 0
        for d in digits {
            value = value << bits | d
        }
        return Tok.Int(value)
    }

    // With `j` just after the `\{` that opens an interpolation: the position
    // of the matching `\}`, or -1.
    fn interpolation_end(self, from: int) -> int {
        var src = self.src
        var j = from
        var depth = 1
        while j < self.end {
            var c = src[j]
            if c == OPEN_BRACE {
                depth += 1
            } else if c == CLOSE_BRACE {
                depth -= 1
                if depth == 0 {
                    return j
                }
            } else if c == QUOTE {
                j = self.string_end(j + 1)
                if j < 0 {
                    return -1
                }
            } else if c == NEWLINE {
                return -1
            }
            j += 1
        }
        return -1
    }

    // With `j` just after the `"` that opens a string: the position of the
    // closing `"`, or -1.
    fn string_end(self, from: int) -> int {
        var src = self.src
        var j = from
        while j < self.end {
            var c = src[j]
            if c == QUOTE {
                return j
            } else if c == BACKSLASH {
                j += 1
            } else if c == OPEN_BRACE {
                j = self.interpolation_end(j + 1)
                if j < 0 {
                    return -1
                }
            } else if c == NEWLINE {
                return -1
            }
            j += 1
        }
        return -1
    }

    fn unterminated(self, open: int) {
        var d = self.report.add("E0002", "unterminated string", open, open + 1)
        d.label = "this string is never closed"
    }

    fn string(self) -> Tok! {
        var src = self.src
        var open = self.at
        var i = open + 1
        var pieces: [Piece] = []
        var lit: [int] = []
        while true {
            if i >= self.end {
                self.unterminated(open)
                fail "syntax"
            }
            var c = src[i]
            if c == QUOTE {
                i += 1
                break
            }
            if c == NEWLINE {
                self.unterminated(open)
                fail "syntax"
            }
            if c == BACKSLASH {
                if i + 1 >= self.end {
                    self.unterminated(open)
                    fail "syntax"
                }
                match chr(src[i + 1]) {
                    "n" {
                        lit.push(10)
                    }
                    "t" {
                        lit.push(9)
                    }
                    "r" {
                        lit.push(13)
                    }
                    "0" {
                        lit.push(0)
                    }
                    "\\" {
                        lit.push(BACKSLASH)
                    }
                    "\"" {
                        lit.push(QUOTE)
                    }
                    "\{" {
                        lit.push(OPEN_BRACE)
                    }
                    "\}" {
                        lit.push(CLOSE_BRACE)
                    }
                    else {
                        var d = self.report.add("E0001", "unknown escape sequence", i, i + 2)
                        d.help = "valid escapes are \\n \\t \\r \\0 \\\\ \\\" \\\{ \\\}"
                        fail "syntax"
                    }
                }
                i += 2
                continue
            }
            if c == OPEN_BRACE {
                // Interpolation: find the matching brace. The code inside may
                // itself contain strings, with interpolations of their own.
                var close = self.interpolation_end(i + 1)
                if close < 0 {
                    var d = self.report.add("E0002", "unterminated `\{` in string", i, i + 1)
                    d.help = "write `\\\{` for a literal brace"
                    fail "syntax"
                }
                if lit.len() > 0 {
                    pieces.push(Piece.Lit(from_bytes(lit)))
                    lit = []
                }
                pieces.push(Piece.Code(i + 1, close))
                i = close + 1
                continue
            }
            lit.push(c)
            i += 1
        }
        if lit.len() > 0 || pieces.len() == 0 {
            pieces.push(Piece.Lit(from_bytes(lit)))
        }
        self.at = i
        return Tok.Str(pieces)
    }

    fn unexpected(self, i: int) {
        var size = char_size(self.src[i])
        var ch = text_of(self.src, i, i + size)
        var d = self.report.add("E0001", "unexpected character `{ch}`", i, i + size)
        if ch == "'" {
            d.help = "strings use double quotes: \"text\""
        }
    }

    fn run(self) -> [Token]! {
        var src = self.src
        var tokens: [Token] = []
        var nl = false
        while self.at < self.end {
            var i = self.at
            var c = src[i]
            // Whitespace
            if c == NEWLINE {
                nl = true
                self.at = i + 1
                continue
            }
            if c == 32 || c == 9 || c == 13 {
                self.at = i + 1
                continue
            }
            // Comments
            if c == 47 && i + 1 < self.end && src[i + 1] == 47 {
                while i < self.end && src[i] != NEWLINE {
                    i += 1
                }
                self.at = i
                continue
            }
            if c == 47 && i + 1 < self.end && src[i + 1] == 42 {
                var open = i
                i += 2
                while true {
                    if i + 1 >= self.end {
                        var d = self.report.add("E0002", "unterminated block comment", open, open + 2)
                        d.label = "this comment is never closed with `*/`"
                        fail "syntax"
                    }
                    if src[i] == 42 && src[i + 1] == 47 {
                        i += 2
                        break
                    }
                    if src[i] == NEWLINE {
                        nl = true
                    }
                    i += 1
                }
                self.at = i
                continue
            }

            var start = i
            var tok = Tok.Eof
            if is_digit(c) {
                tok = self.number()?
            } else if c == QUOTE {
                tok = self.string()?
            } else if is_letter(c) {
                while i < self.end && (is_letter(src[i]) || is_digit(src[i])) {
                    i += 1
                }
                self.at = i
                tok = keyword(text_of(src, start, i))
            } else {
                var next = 0
                if i + 1 < self.end {
                    next = src[i + 1]
                }
                var size = 2
                tok = double(c, next) catch err {
                    size = 1
                    Tok.Eof
                }
                if size == 1 {
                    tok = single(c) catch err {
                        self.unexpected(i)
                        fail "syntax"
                    }
                }
                self.at = i + size
            }
            tokens.push(Token{tok: tok, start: start, end: self.at, nl_before: nl})
            nl = false
        }
        tokens.push(Token{tok: Tok.Eof, start: self.end, end: self.end, nl_before: true})
        return tokens
    }
}

// Lexes the bytes of `src` from `start` to `end`. Positions are counted from
// the start of `src`, which lets the parser lex the code inside string
// interpolations again with the right positions.
fn lex(src: [int], start: int, end: int, report: diag.Report) -> [Token]! {
    var lexer = Lexer{src: src, end: end, at: start, report: report}
    return lexer.run()?
}
