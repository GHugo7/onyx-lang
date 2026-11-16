// The Onyx compiler, written in Onyx. (In progress: see docs/selfhost.md.)

import "diag"
import "lexer"

// The name of a token, as the compiler written in Rust calls it.
fn tok_name(t: lexer.Tok) -> string {
    var shown = str(t).split("(")[0]
    var parts = shown.split(".")
    return parts[parts.len() - 1]
}

fn quote(text: string) -> string {
    var out = "\""
    for c in text {
        match c {
            "\\" {
                out += "\\\\"
            }
            "\"" {
                out += "\\\""
            }
            "\n" {
                out += "\\n"
            }
            "\t" {
                out += "\\t"
            }
            "\r" {
                out += "\\r"
            }
            "\0" {
                out += "\\0"
            }
            else {
                out += c
            }
        }
    }
    return out + "\""
}

// Prints what the lexer makes of a file, one token per line, in the same
// form as `onyx tokens` of the compiler written in Rust.
fn dump_tokens(path: string) -> void! {
    var src = read_bytes(path)?
    var report = diag.new_report()
    var tokens = lexer.lex(src, 0, src.len(), report) catch err {
        for d in report.diags {
            print("error {d.code} {d.start} {d.end} {d.message}")
        }
        return
    }
    for t in tokens {
        var nl = 0
        if t.nl_before {
            nl = 1
        }
        var line = "{t.start} {t.end} {nl} {tok_name(t.tok)}"
        match t.tok {
            Int(n) {
                line += " {n}"
            }
            Float(_) {
                line += " " + lexer.text_of(src, t.start, t.end)
            }
            Ident(word) {
                line += " " + word
            }
            Str(pieces) {
                for piece in pieces {
                    match piece {
                        Lit(text) {
                            line += " L" + quote(text)
                        }
                        Code(start, end) {
                            line += " C{start}:{end}"
                        }
                    }
                }
            }
            else {
            }
        }
        print(line)
    }
}

fn main() -> void! {
    var arguments = args()
    if arguments.len() == 2 && arguments[0] == "tokens" {
        dump_tokens(arguments[1])?
        return
    }
    print("usage: tokens <file.ox>")
    exit(2)
}
