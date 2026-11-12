//! Turns source text into tokens.

use crate::diagnostics::{Diagnostic, Span};

#[derive(Debug, Clone, PartialEq)]
pub enum StrPiece {
    Lit(String),
    /// An interpolated `{expression}`; the byte range of the code inside the braces.
    Code { start: usize, end: usize },
}

#[derive(Debug, Clone, PartialEq)]
pub enum Tok {
    Int(i64),
    Float(f64),
    Str(Vec<StrPiece>),
    Ident(String),
    // Keywords
    Fn,
    Let,
    Const,
    Struct,
    Interface,
    If,
    Else,
    While,
    For,
    In,
    Return,
    Break,
    Continue,
    Fail,
    Or,
    Catch,
    Fork,
    Chan,
    Check,
    True,
    False,
    // Punctuation
    LParen,
    RParen,
    LBrace,
    RBrace,
    LBracket,
    RBracket,
    Comma,
    Colon,
    Semi,
    Dot,
    DotDot,
    Arrow,
    LArrow,
    Eq,
    EqEq,
    NotEq,
    Lt,
    Le,
    Gt,
    Ge,
    Plus,
    Minus,
    Star,
    Slash,
    Percent,
    Bang,
    AndAnd,
    OrOr,
    Question,
    PlusEq,
    MinusEq,
    StarEq,
    SlashEq,
    Eof,
}

impl Tok {
    /// Human-readable form for error messages.
    pub fn describe(&self) -> String {
        match self {
            Tok::Int(_) | Tok::Float(_) => "a number".into(),
            Tok::Str(_) => "a string".into(),
            Tok::Ident(name) => format!("`{name}`"),
            Tok::Eof => "end of file".into(),
            other => format!("`{}`", other.text()),
        }
    }

    fn text(&self) -> &'static str {
        match self {
            Tok::Fn => "fn",
            Tok::Let => "let",
            Tok::Const => "const",
            Tok::Struct => "struct",
            Tok::Interface => "interface",
            Tok::If => "if",
            Tok::Else => "else",
            Tok::While => "while",
            Tok::For => "for",
            Tok::In => "in",
            Tok::Return => "return",
            Tok::Break => "break",
            Tok::Continue => "continue",
            Tok::Fail => "fail",
            Tok::Or => "or",
            Tok::Catch => "catch",
            Tok::Fork => "fork",
            Tok::Chan => "chan",
            Tok::Check => "check",
            Tok::True => "true",
            Tok::False => "false",
            Tok::LParen => "(",
            Tok::RParen => ")",
            Tok::LBrace => "{",
            Tok::RBrace => "}",
            Tok::LBracket => "[",
            Tok::RBracket => "]",
            Tok::Comma => ",",
            Tok::Colon => ":",
            Tok::Semi => ";",
            Tok::Dot => ".",
            Tok::DotDot => "..",
            Tok::Arrow => "->",
            Tok::LArrow => "<-",
            Tok::Eq => "=",
            Tok::EqEq => "==",
            Tok::NotEq => "!=",
            Tok::Lt => "<",
            Tok::Le => "<=",
            Tok::Gt => ">",
            Tok::Ge => ">=",
            Tok::Plus => "+",
            Tok::Minus => "-",
            Tok::Star => "*",
            Tok::Slash => "/",
            Tok::Percent => "%",
            Tok::Bang => "!",
            Tok::AndAnd => "&&",
            Tok::OrOr => "||",
            Tok::Question => "?",
            Tok::PlusEq => "+=",
            Tok::MinusEq => "-=",
            Tok::StarEq => "*=",
            Tok::SlashEq => "/=",
            _ => "?",
        }
    }
}

#[derive(Debug, Clone)]
pub struct Token {
    pub tok: Tok,
    pub span: Span,
    /// True when at least one line break separates this token from the previous one.
    pub nl_before: bool,
}

fn keyword(word: &str) -> Option<Tok> {
    Some(match word {
        "fn" => Tok::Fn,
        "let" => Tok::Let,
        "const" => Tok::Const,
        "struct" => Tok::Struct,
        "interface" => Tok::Interface,
        "if" => Tok::If,
        "else" => Tok::Else,
        "while" => Tok::While,
        "for" => Tok::For,
        "in" => Tok::In,
        "return" => Tok::Return,
        "break" => Tok::Break,
        "continue" => Tok::Continue,
        "fail" => Tok::Fail,
        "or" => Tok::Or,
        "catch" => Tok::Catch,
        "fork" => Tok::Fork,
        "chan" => Tok::Chan,
        "check" => Tok::Check,
        "true" => Tok::True,
        "false" => Tok::False,
        _ => return None,
    })
}

/// Lexes `src[start..end]`. Spans are relative to the whole of `src`, which lets
/// the parser re-lex the code inside string interpolations with correct positions.
pub fn lex(src: &str, start: usize, end: usize) -> Result<Vec<Token>, Diagnostic> {
    let bytes = src.as_bytes();
    let mut tokens = Vec::new();
    let mut i = start;
    let mut nl = false;

    while i < end {
        let c = bytes[i];
        // Whitespace
        if c == b'\n' {
            nl = true;
            i += 1;
            continue;
        }
        if c == b' ' || c == b'\t' || c == b'\r' {
            i += 1;
            continue;
        }
        // Comments
        if c == b'/' && i + 1 < end && bytes[i + 1] == b'/' {
            while i < end && bytes[i] != b'\n' {
                i += 1;
            }
            continue;
        }
        if c == b'/' && i + 1 < end && bytes[i + 1] == b'*' {
            let open = i;
            i += 2;
            loop {
                if i + 1 >= end {
                    return Err(Diagnostic::new(
                        "E0002",
                        "unterminated block comment",
                        Span::new(open, open + 2),
                    )
                    .label("this comment is never closed with `*/`"));
                }
                if bytes[i] == b'*' && bytes[i + 1] == b'/' {
                    i += 2;
                    break;
                }
                if bytes[i] == b'\n' {
                    nl = true;
                }
                i += 1;
            }
            continue;
        }

        let tok_start = i;
        let tok = if c.is_ascii_digit() {
            lex_number(src, &mut i, end)?
        } else if c == b'"' {
            lex_string(src, &mut i, end)?
        } else if c == b'_' || c.is_ascii_alphabetic() || c >= 0x80 {
            let ch = src[i..].chars().next().unwrap();
            if c >= 0x80 && !ch.is_alphabetic() {
                return Err(Diagnostic::new(
                    "E0001",
                    format!("unexpected character `{ch}`"),
                    Span::new(i, i + ch.len_utf8()),
                ));
            }
            while i < end {
                let ch = src[i..].chars().next().unwrap();
                if ch == '_' || ch.is_alphanumeric() {
                    i += ch.len_utf8();
                } else {
                    break;
                }
            }
            let word = &src[tok_start..i];
            keyword(word).unwrap_or_else(|| Tok::Ident(word.to_string()))
        } else {
            let next = if i + 1 < end { bytes[i + 1] } else { 0 };
            let (tok, len) = match (c, next) {
                (b'.', b'.') => (Tok::DotDot, 2),
                (b'-', b'>') => (Tok::Arrow, 2),
                (b'<', b'-') => (Tok::LArrow, 2),
                (b'=', b'=') => (Tok::EqEq, 2),
                (b'!', b'=') => (Tok::NotEq, 2),
                (b'<', b'=') => (Tok::Le, 2),
                (b'>', b'=') => (Tok::Ge, 2),
                (b'&', b'&') => (Tok::AndAnd, 2),
                (b'|', b'|') => (Tok::OrOr, 2),
                (b'+', b'=') => (Tok::PlusEq, 2),
                (b'-', b'=') => (Tok::MinusEq, 2),
                (b'*', b'=') => (Tok::StarEq, 2),
                (b'/', b'=') => (Tok::SlashEq, 2),
                (b'(', _) => (Tok::LParen, 1),
                (b')', _) => (Tok::RParen, 1),
                (b'{', _) => (Tok::LBrace, 1),
                (b'}', _) => (Tok::RBrace, 1),
                (b'[', _) => (Tok::LBracket, 1),
                (b']', _) => (Tok::RBracket, 1),
                (b',', _) => (Tok::Comma, 1),
                (b':', _) => (Tok::Colon, 1),
                (b';', _) => (Tok::Semi, 1),
                (b'.', _) => (Tok::Dot, 1),
                (b'=', _) => (Tok::Eq, 1),
                (b'<', _) => (Tok::Lt, 1),
                (b'>', _) => (Tok::Gt, 1),
                (b'+', _) => (Tok::Plus, 1),
                (b'-', _) => (Tok::Minus, 1),
                (b'*', _) => (Tok::Star, 1),
                (b'/', _) => (Tok::Slash, 1),
                (b'%', _) => (Tok::Percent, 1),
                (b'!', _) => (Tok::Bang, 1),
                (b'?', _) => (Tok::Question, 1),
                _ => {
                    let ch = src[i..].chars().next().unwrap();
                    let mut d = Diagnostic::new(
                        "E0001",
                        format!("unexpected character `{ch}`"),
                        Span::new(i, i + ch.len_utf8()),
                    );
                    if ch == '\'' {
                        d = d.help("strings use double quotes: \"text\"");
                    } else if ch == '&' || ch == '|' {
                        d = d.help(format!("the logical operator is `{ch}{ch}`"));
                    }
                    return Err(d);
                }
            };
            i += len;
            tok
        };
        tokens.push(Token { tok, span: Span::new(tok_start, i), nl_before: nl });
        nl = false;
    }
    tokens.push(Token { tok: Tok::Eof, span: Span::new(end, end), nl_before: true });
    Ok(tokens)
}

fn lex_number(src: &str, i: &mut usize, end: usize) -> Result<Tok, Diagnostic> {
    let bytes = src.as_bytes();
    let start = *i;
    while *i < end && (bytes[*i].is_ascii_digit() || bytes[*i] == b'_') {
        *i += 1;
    }
    let mut is_float = false;
    // A fraction needs a digit after the dot, so `1..5` and `1.str()` still work.
    if *i + 1 < end && bytes[*i] == b'.' && bytes[*i + 1].is_ascii_digit() {
        is_float = true;
        *i += 1;
        while *i < end && (bytes[*i].is_ascii_digit() || bytes[*i] == b'_') {
            *i += 1;
        }
    }
    let text: String = src[start..*i].chars().filter(|c| *c != '_').collect();
    let span = Span::new(start, *i);
    if is_float {
        text.parse::<f64>()
            .map(Tok::Float)
            .map_err(|_| Diagnostic::new("E0001", "invalid number", span))
    } else {
        text.parse::<i64>().map(Tok::Int).map_err(|_| {
            Diagnostic::new("E0001", "integer literal is too large", span)
                .label("does not fit in an int")
        })
    }
}

fn lex_string(src: &str, i: &mut usize, end: usize) -> Result<Tok, Diagnostic> {
    let bytes = src.as_bytes();
    let open = *i;
    *i += 1;
    let mut pieces = Vec::new();
    let mut lit = String::new();
    let unterminated = || {
        Diagnostic::new("E0002", "unterminated string", Span::new(open, open + 1))
            .label("this string is never closed")
    };
    loop {
        if *i >= end {
            return Err(unterminated());
        }
        let c = bytes[*i];
        match c {
            b'"' => {
                *i += 1;
                break;
            }
            b'\n' => return Err(unterminated()),
            b'\\' => {
                if *i + 1 >= end {
                    return Err(unterminated());
                }
                let esc = bytes[*i + 1];
                lit.push(match esc {
                    b'n' => '\n',
                    b't' => '\t',
                    b'r' => '\r',
                    b'0' => '\0',
                    b'\\' => '\\',
                    b'"' => '"',
                    b'{' => '{',
                    b'}' => '}',
                    _ => {
                        return Err(Diagnostic::new(
                            "E0001",
                            "unknown escape sequence",
                            Span::new(*i, *i + 2),
                        )
                        .help("valid escapes are \\n \\t \\r \\0 \\\\ \\\" \\{ \\}"));
                    }
                });
                *i += 2;
            }
            b'{' => {
                // Interpolation: find the matching brace, skipping nested strings.
                let code_start = *i + 1;
                let mut depth = 1;
                let mut j = code_start;
                while j < end && depth > 0 {
                    match bytes[j] {
                        b'{' => depth += 1,
                        b'}' => depth -= 1,
                        b'"' => {
                            j += 1;
                            while j < end && bytes[j] != b'"' {
                                if bytes[j] == b'\\' {
                                    j += 1;
                                }
                                if j < end && bytes[j] == b'\n' {
                                    return Err(unterminated());
                                }
                                j += 1;
                            }
                        }
                        b'\n' => return Err(unterminated()),
                        _ => {}
                    }
                    j += 1;
                }
                if depth != 0 {
                    return Err(Diagnostic::new(
                        "E0002",
                        "unterminated `{` in string",
                        Span::new(*i, *i + 1),
                    )
                    .help("write `\\{` for a literal brace"));
                }
                if !lit.is_empty() {
                    pieces.push(StrPiece::Lit(std::mem::take(&mut lit)));
                }
                pieces.push(StrPiece::Code { start: code_start, end: j - 1 });
                *i = j;
            }
            _ => {
                let ch = src[*i..].chars().next().unwrap();
                lit.push(ch);
                *i += ch.len_utf8();
            }
        }
    }
    if !lit.is_empty() || pieces.is_empty() {
        pieces.push(StrPiece::Lit(lit));
    }
    Ok(Tok::Str(pieces))
}
