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

/// Long-form explanations of the error codes, shown by `onyx explain <CODE>`:
/// the sections of docs/errors.md, which the compiler written in Onyx reads too.
const EXPLANATIONS: &str = include_str!("../docs/errors.md");

pub fn explain(code: &str) -> Option<&'static str> {
    let heading = format!("\n## {code}\n");
    let start = EXPLANATIONS.find(&heading)? + heading.len();
    let rest = &EXPLANATIONS[start..];
    let end = rest.find("\n## ").unwrap_or(rest.len());
    Some(rest[..end].trim())
}
