// The Onyx compiler, written in Onyx. (In progress: see docs/selfhost.md.)

import "capture"
import "checker"
import "desugar"
import "diag"
import "dump"
import "gen"
import "lexer"
import "lower"
import "modules"
import "optimize"
import "parser"
import "widen"

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
    var out = dump.Dump{src: src, lines: [], ids: false}
    out.program(program)
    for line in out.lines {
        print(line)
    }
}

// Prints the program once its files are linked into one, in the same form
// as `onyx modules` of the compiler written in Rust.
fn dump_modules(path: string) {
    var report = diag.new_report()
    var linked = modules.load(path, false, report) catch err {
        if err.message == "fatal" {
            print("fatal")
        }
        for d in report.diags {
            print("error {d.code} {d.start} {d.end} {d.message}")
        }
        return
    }
    var out = dump.Dump{src: linked.sources.bytes, lines: [], ids: false}
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
    var linked = modules.load(path, false, report) catch err {
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

// Prints the program as the native code generator receives it, in the same
// form as `onyx lowered` of the compiler written in Rust.
fn dump_lowered(path: string) {
    var report = diag.new_report()
    var linked = modules.load(path, true, report) catch err {
        if err.message == "fatal" {
            print("fatal")
        }
        for d in report.diags {
            print_diag(d)
        }
        return
    }
    var program = linked.program
    var an = checker.check(program, linked.sources.bytes, true, linked.runtime_start, linked.runtime_end, report) catch err {
        for d in report.diags {
            print_diag(d)
        }
        return
    }
    desugar.desugar(program, an)
    optimize.optimize(program)
    widen.widen(program, an)
    capture.capture(program, an)
    lower.lower(program, an)
    var out = dump.Dump{src: linked.sources.bytes, lines: [], ids: true}
    out.program(program)
    for line in out.lines {
        print(line)
    }
    for line in checker.dump(an) {
        print(line)
    }
    for id in an.captures.keys().sort() {
        var shown: [string] = []
        for c in an.captures[id] {
            shown.push(c.name + ": " + checker.show(c.ty))
        }
        print("captures {id} " + shown.join(", "))
    }
    print("forks {an.has_forks}")
}

// Compiles a program to an executable for Linux x86-64, as
// `onyx build --target native` does: the same bytes.
fn build(path: string, out: string, leak_check: bool) -> bool {
    var report = diag.new_report()
    var linked = modules.load(path, true, report) catch err {
        if err.message == "fatal" {
            print("cannot read `{path}`")
        }
        for d in report.diags {
            print_diag(d)
        }
        return false
    }
    var program = linked.program
    var an = checker.check(program, linked.sources.bytes, true, linked.runtime_start, linked.runtime_end, report) catch err {
        for d in report.diags {
            print_diag(d)
        }
        return false
    }
    desugar.desugar(program, an)
    optimize.optimize(program)
    widen.widen(program, an)
    capture.capture(program, an)
    lower.lower(program, an)
    var executable = gen.generate(program, an, leak_check, report) catch err {
        for d in report.diags {
            print_diag(d)
        }
        return false
    }
    write_bytes(out, executable) catch err {
        print(err.message)
        return false
    }
    set_executable(out) catch err {
        print(err.message)
        return false
    }
    return true
}

fn main() -> void! {
    var arguments = args()
    if arguments.len() >= 4 && arguments[0] == "build" && arguments[arguments.len() - 2] == "-o" {
        var leak_check = arguments.contains("--leak-check")
        if !build(arguments[arguments.len() - 3], arguments[arguments.len() - 1], leak_check) {
            exit(1)
        }
        return
    }
    if arguments.len() == 2 && arguments[0] == "lowered" {
        dump_lowered(arguments[1])
        return
    }
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
    print("usage: tokens <file.ox> | ast <file.ox> | modules <file.ox> | types <file.ox> | lowered <file.ox> | build [--leak-check] <file.ox> -o <out>")
    exit(2)
}
