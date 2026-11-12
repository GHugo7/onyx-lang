//! Compiler diagnostics: spans, error values, and rustc-style rendering.

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Span {
    pub start: usize,
    pub end: usize,
}

impl Span {
    pub fn new(start: usize, end: usize) -> Span {
        Span { start, end }
    }
    pub fn to(self, other: Span) -> Span {
        Span { start: self.start.min(other.start), end: self.end.max(other.end) }
    }
}

#[derive(Debug, Clone)]
pub struct Diagnostic {
    pub code: &'static str,
    pub message: String,
    pub span: Span,
    pub label: String,
    pub help: Option<String>,
}

impl Diagnostic {
    pub fn new(code: &'static str, message: impl Into<String>, span: Span) -> Diagnostic {
        Diagnostic { code, message: message.into(), span, label: String::new(), help: None }
    }
    pub fn label(mut self, label: impl Into<String>) -> Diagnostic {
        self.label = label.into();
        self
    }
    pub fn help(mut self, help: impl Into<String>) -> Diagnostic {
        self.help = Some(help.into());
        self
    }
}

/// All the source files of a program, stored back to back in one buffer so
/// that a `Span` (a pair of offsets into that buffer) also identifies its file.
#[derive(Default)]
pub struct SourceMap {
    pub text: String,
    files: Vec<SourceFile>,
}

struct SourceFile {
    name: String,
    start: usize,
    end: usize,
}

pub struct Location<'a> {
    pub file: &'a str,
    /// The text of that file only.
    pub text: &'a str,
    pub line: usize,
    pub col: usize,
    /// Offset of the location inside `text`.
    pub offset: usize,
}

impl SourceMap {
    /// Adds a file and returns its byte range in the buffer.
    pub fn add(&mut self, name: String, text: &str) -> (usize, usize) {
        if !self.text.is_empty() {
            self.text.push('\n');
        }
        let start = self.text.len();
        self.text.push_str(text);
        let end = self.text.len();
        self.files.push(SourceFile { name, start, end });
        (start, end)
    }

    pub fn locate(&self, offset: usize) -> Location<'_> {
        let file = self
            .files
            .iter()
            .find(|f| offset <= f.end)
            .or(self.files.last())
            .expect("no source files");
        let text = &self.text[file.start..file.end];
        let offset = offset.clamp(file.start, file.end) - file.start;
        let (line, col) = line_col(text, offset);
        Location { file: &file.name, text, line, col, offset }
    }
}

/// Returns the 1-based (line, column) of a byte offset.
fn line_col(src: &str, offset: usize) -> (usize, usize) {
    let offset = offset.min(src.len());
    let mut line = 1;
    let mut line_start = 0;
    for (i, b) in src.bytes().enumerate() {
        if i >= offset {
            break;
        }
        if b == b'\n' {
            line += 1;
            line_start = i + 1;
        }
    }
    let col = src[line_start..offset].chars().count() + 1;
    (line, col)
}

pub fn render(d: &Diagnostic, sources: &SourceMap, color: bool) -> String {
    let (red, blue, bold, reset) =
        if color { ("\x1b[1;31m", "\x1b[1;34m", "\x1b[1m", "\x1b[0m") } else { ("", "", "", "") };
    let loc = sources.locate(d.span.start);
    let (file, src, line, col) = (loc.file, loc.text, loc.line, loc.col);
    let line_text = src.lines().nth(line - 1).unwrap_or("");
    let span_len = d.span.end.saturating_sub(d.span.start);
    let gutter = " ".repeat(line.to_string().len());
    // Underline only the part of the span that sits on the first line.
    let span_chars = src
        .get(loc.offset..(loc.offset + span_len).min(src.len()))
        .map(|s| s.split('\n').next().unwrap_or("").chars().count())
        .unwrap_or(1)
        .max(1);
    let pad: String =
        line_text.chars().take(col - 1).map(|c| if c == '\t' { '\t' } else { ' ' }).collect();

    let mut out = String::new();
    out.push_str(&format!("{red}error[{}]{reset}{bold}: {}{reset}\n", d.code, d.message));
    out.push_str(&format!("{gutter}{blue}-->{reset} {file}:{line}:{col}\n"));
    out.push_str(&format!("{gutter} {blue}|{reset}\n"));
    out.push_str(&format!("{blue}{line} |{reset} {line_text}\n"));
    out.push_str(&format!(
        "{gutter} {blue}|{reset} {pad}{red}{}{}{reset}\n",
        "^".repeat(span_chars),
        if d.label.is_empty() { String::new() } else { format!(" {}", d.label) }
    ));
    if let Some(help) = &d.help {
        out.push_str(&format!("{gutter} {blue}|{reset}\n"));
        out.push_str(&format!("{gutter} {blue}={reset} {bold}help{reset}: {help}\n"));
    }
    out
}

/// Long-form explanations, shown by `onyx explain <CODE>`.
pub fn explain(code: &str) -> Option<&'static str> {
    Some(match code {
        "E0001" => "The source file contains a character that is not part of the Onyx language.",
        "E0002" => "A string literal or block comment was opened but never closed.\n\nStrings start and end with a double quote: \"hello\".\nTo write a literal `{` inside a string, escape it: \"\\{\".",
        "E0003" => "The parser found a token it did not expect. Check for a missing brace,\nparenthesis, comma or type annotation near the reported location.",
        "E0100" => "A name was used that is not defined in the current scope.\n\nVariables must be declared with `var` or `const` before they are used,\nand functions must exist at the top level of the file.",
        "E0101" => "A type name was used that does not exist.\n\nBuilt-in types are: int, float, bool, string, void, error, [T], map<K, V>,\nchan<T> and fn(A) -> R. Other types must be declared with `struct` or `interface`.",
        "E0102" => "An expression has a different type from the one required.\n\nOnyx is statically typed: every value has one type, known at compile time.\nThe only implicit conversion is int -> float. Use int(x), float(x) or str(x)\nto convert explicitly.\n\n    var n: int = \"hello\"      // error\n    var n: int = parse_int(\"42\") or 0   // ok",
        "E0103" => "The same name was defined twice in one scope.",
        "E0104" => "A function was called with the wrong number of arguments.",
        "E0105" => "Only functions and methods can be called.",
        "E0106" => "The field or method does not exist on this type.",
        "E0107" => "An operator was applied to types it does not support.\n\nArithmetic works on int and float, `+` also joins two strings,\n`&&`, `||` and `!` work on bool. To build a string from other values,\nuse interpolation: \"score: {n}\".",
        "E0108" => "A `const` binding (or a loop variable) cannot be reassigned.\nDeclare it with `var` if it needs to change.",
        "E0109" => "A function with a return type must return a value on every path.",
        "E0110" => "The compiler could not infer a type, usually for an empty list `[]` or\nan empty map `{}`. Add a type annotation:\n\n    var names: [string] = []",
        "E0111" => "`break` and `continue` can only be used inside a `while` or `for` loop.",
        "E0112" => "A struct literal must give a value to every field, exactly once,\nand cannot mention fields that do not exist.",
        "E0113" => "Map keys must be of type int, string or bool.",
        "E0114" => "`for ... in` works on lists, strings, maps (keys), channels and ranges (a..b).",
        "E0115" => "Only lists, maps and strings can be indexed with `[...]`.",
        "E0116" => "A program needs an entry point:\n\n    fn main() {\n        print(\"hello\")\n    }",
        "E0117" => "`return` cannot be used here (for example inside a `fork` block,\nwhich runs as a separate task).",
        "E0200" => "A function whose return type ends with `!` can fail. Onyx does not let you\nignore that: every call must say what happens on failure.\n\n    var data = read_file(\"a.txt\")?              // pass the error to my caller\n    var data = read_file(\"a.txt\") or \"\"         // use a default value\n    var data = read_file(\"a.txt\") catch err {   // handle it here\n        print(\"oops: {err}\")\n        return\n    }",
        "E0201" => "`?` passes an error up to the caller, so it can only be used inside a\nfunction that can itself fail (its return type ends with `!`).\n\n    fn load() -> string! {\n        return read_file(\"a.txt\")?\n    }",
        "E0202" => "`?`, `or` and `catch` handle the error of a call that can fail.\nHere the expression can never fail, so there is nothing to handle.\n\nNote that `or` has the lowest precedence; use parentheses when mixing it\nwith other operators: 1 + (parse_int(s) or 0)",
        "E0203" => "`fail` reports an error to the caller, so it can only be used inside a\nfunction whose return type ends with `!`.",
        "E0204" => "When a `catch` block is used to produce a value, it must either leave\n(return, fail, break, continue) or end with an expression of the right type.",
        "E0205" => "`catch` blocks may contain statements such as `return`, so they are only\nallowed directly in a `var`, an assignment, a `return` or as a statement.\nUse `or` inside larger expressions.",
        "E0206" => "The `!` marker is only valid on a function's return type.",
        "E0400" => "An `import` names a file that does not exist or cannot be read.\n\nImport paths are relative to the file that contains the import, and the\n`.ox` extension is optional:\n\n    import \"utils\"            // ./utils.ox\n    import \"lib/geometry\"     // ./lib/geometry.ox",
        "E0401" => "A module was asked for something it does not define, or for a private\nname. After `import \"utils\"`, the functions, variables and types of\nutils.ox are used as `utils.name`. Names starting with `_` stay private to\ntheir file.",
        "E0402" => "Every import needs a distinct, valid name. By default it is the file name;\nchoose another one with `as`:\n\n    import \"lib/string-utils\" as strings",
        "E0500" => "The native target (`--target native`) builds a real Linux executable\nwithout any other tool, but it does not support the whole language yet.\nThe same program runs on the JavaScript target with `onyx run`.",
        "E0300" => "`<-` sends to and receives from channels only.",
        _ => return None,
    })
}
