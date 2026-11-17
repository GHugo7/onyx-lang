// The Onyx compiler, written in Onyx. (In progress: see docs/selfhost.md.)

import "checker"
import "diag"
import "dump"
import "lexer"
import "modules"
import "parser"

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
        var line = "{t.start} {t.end} {nl} {dump.variant_name(str(t.tok))}"
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
                            line += " L" + dump.quote(text)
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

// Prints the syntax tree of a file, in the same form as `onyx ast` of the
// compiler written in Rust.
fn dump_ast(path: string) -> void! {
    var src = read_bytes(path)?
    var report = diag.new_report()
    var program = parser.parse(src, 0, src.len(), 0, report) catch err {
        for d in report.diags {
            print("error {d.code} {d.start} {d.end} {d.message}")
        }
        return
    }
    var out = dump.Dump{src: src, lines: []}
    out.program(program)
    for line in out.lines {
        print(line)
    }
}

// Prints the program once its files are linked into one, in the same form
// as `onyx modules` of the compiler written in Rust.
fn dump_modules(path: string) {
    var report = diag.new_report()
    var linked = modules.load(path, report) catch err {
        if err.message == "fatal" {
            print("fatal")
        }
        for d in report.diags {
            print("error {d.code} {d.start} {d.end} {d.message}")
        }
        return
    }
    var out = dump.Dump{src: linked.sources.bytes, lines: []}
    out.program(linked.program)
    for line in out.lines {
        print(line)
    }
}

// A problem, in full, as `onyx types` of the compiler written in Rust prints it.
fn print_diag(d: diag.Diag) {
    print("error {d.code} {d.start}:{d.end} {d.message}")
    if d.label != "" {
        print("  label: " + d.label)
    }
    if d.help != "" {
        print("  help: " + d.help)
    }
}

// Prints what the type checker finds out about a program, in the same form
// as `onyx types` of the compiler written in Rust.
fn dump_types(path: string) {
    var report = diag.new_report()
    var linked = modules.load(path, report) catch err {
        if err.message == "fatal" {
            print("fatal")
        }
        for d in report.diags {
            print_diag(d)
        }
        return
    }
    var analysis = checker.check(linked.program, linked.sources.bytes, true, -1, -1, report) catch err {
        for d in report.diags {
            print_diag(d)
        }
        return
    }
    for line in checker.dump(analysis) {
        print(line)
    }
}

fn main() -> void! {
    var arguments = args()
    if arguments.len() == 2 && arguments[0] == "types" {
        dump_types(arguments[1])
        return
    }
    if arguments.len() == 2 && arguments[0] == "modules" {
        dump_modules(arguments[1])
        return
    }
    if arguments.len() == 2 && arguments[0] == "ast" {
        dump_ast(arguments[1])?
        return
    }
    if arguments.len() == 2 && arguments[0] == "tokens" {
        dump_tokens(arguments[1])?
        return
    }
    print("usage: tokens <file.ox> | ast <file.ox> | modules <file.ox> | types <file.ox>")
    exit(2)
}
