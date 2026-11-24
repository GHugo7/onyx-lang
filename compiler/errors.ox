// How the compiler shows a problem: the place in the source, with its line
// and a mark under the spot, as src/diagnostics.rs renders it. And the long
// explanations of the error codes, `onyx explain`.

import "diag"
import "modules"

// The explanations: the sections of docs/errors.md, one per code.
const EXPLANATIONS = embed("../docs/errors.md")

// The explanation of an error code (none: there is no such code).
fn explain(code: string) -> [string] {
    var heading = "\n## " + code + "\n"
    var at = EXPLANATIONS.index_of(heading)
    if at < 0 {
        return []
    }
    var rest = EXPLANATIONS.slice(at + heading.len(), EXPLANATIONS.len())
    var end = rest.index_of("\n## ")
    if end < 0 {
        end = rest.len()
    }
    return [rest.slice(0, end).trim()]
}

// Where a position of the sources is.
struct Location {
    file: string
    // Where the text of that file is in the sources.
    start: int
    end: int
    // From 1.
    line: int
    col: int
    // The position, from the start of the file.
    offset: int
    // Where its line starts, from the start of the file.
    line_start: int
}

// The number of characters in some bytes of UTF-8.
fn char_count(bytes: [int], from: int, to: int) -> int {
    var n = 0
    for i in from..to {
        if bytes[i] & 0xC0 != 0x80 {
            n += 1
        }
    }
    return n
}

fn locate(sources: modules.Sources, position: int) -> Location {
    // The first file that ends at or after the position (the last one otherwise).
    var file = sources.files[sources.files.len() - 1]
    for i in 0..sources.files.len() {
        if position <= sources.files[i].end {
            file = sources.files[i]
            break
        }
    }
    var offset = min(max(position, file.start), file.end) - file.start
    var line = 1
    var line_start = 0
    for i in 0..offset {
        if sources.bytes[file.start + i] == 10 {
            line += 1
            line_start = i + 1
        }
    }
    var col = char_count(sources.bytes, file.start + line_start, file.start + offset) + 1
    return Location{file: file.name, start: file.start, end: file.end, line: line, col: col, offset: offset, line_start: line_start}
}

// The problem as it is shown: in color for a terminal.
fn render(d: diag.Diag, sources: modules.Sources, color: bool) -> string {
    var red = ""
    var blue = ""
    var bold = ""
    var reset = ""
    if color {
        var escape = chr(27)
        red = escape + "[1;31m"
        blue = escape + "[1;34m"
        bold = escape + "[1m"
        reset = escape + "[0m"
    }
    var loc = locate(sources, d.start)
    var bytes = sources.bytes
    // The line of the problem, without its line break.
    var line_end = loc.start + loc.line_start
    while line_end < loc.end && bytes[line_end] != 10 {
        line_end += 1
    }
    var text_end = line_end
    if line_end < loc.end && text_end > loc.start + loc.line_start && bytes[text_end - 1] == 13 {
        text_end -= 1
    }
    var line_text = from_bytes(bytes.slice(loc.start + loc.line_start, text_end))
    var gutter = " ".repeat(str(loc.line).len())
    // Only the part of the place that is on its first line is marked.
    var span_len = max(d.end - d.start, 0)
    var mark_end = min(loc.start + loc.offset + span_len, loc.end)
    var first_line_end = loc.start + loc.offset
    while first_line_end < mark_end && bytes[first_line_end] != 10 {
        first_line_end += 1
    }
    var marks = max(char_count(bytes, loc.start + loc.offset, first_line_end), 1)
    var pad = ""
    var taken = 0
    for c in line_text {
        if taken < loc.col - 1 {
            if c == "\t" {
                pad += "\t"
            } else {
                pad += " "
            }
            taken += 1
        }
    }
    var label = ""
    if d.label != "" {
        label = " " + d.label
    }
    var out = red + "error[" + d.code + "]" + reset + bold + ": " + d.message + reset + "\n"
    out += gutter + blue + "-->" + reset + " " + loc.file + ":" + str(loc.line) + ":" + str(loc.col) + "\n"
    out += gutter + " " + blue + "|" + reset + "\n"
    out += blue + str(loc.line) + " |" + reset + " " + line_text + "\n"
    out += gutter + " " + blue + "|" + reset + " " + pad + red + "^".repeat(marks) + label + reset + "\n"
    if d.help != "" {
        out += gutter + " " + blue + "|" + reset + "\n"
        out += gutter + " " + blue + "=" + reset + " " + bold + "help" + reset + ": " + d.help + "\n"
    }
    return out
}
