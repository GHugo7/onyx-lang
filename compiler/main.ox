// The `onyx` command, written in Onyx: the same commands, options, messages
// and exit codes as the one written in Rust (src/main.rs). See
// docs/selfhost.md.

import "capture"
import "checker"
import "desugar"
import "diag"
import "errors"
import "gen"
import "js"
import "jvm"
import "lower"
import "modules"
import "optimize"
import "stages"
import "widen"

fn usage() -> string {
    return [
        "Onyx - a small, statically typed programming language",
        "",
        "Usage:",
        "  onyx run <file.ox> [args...]     Compile and run a program",
        "  onyx build <file.ox> [-o <out>]  Compile to build/<name>.js, build/<name> with --target native,",
        "                                   or build/<name>.jar with --target jvm",
        "  onyx check <file.ox>             Check a program for errors without running it",
        "  onyx test [file.ox | folder]     Run the `check` blocks of a file and of its `name.test.ox`",
        "                                   file; without a file, every test of the folder",
        "  onyx explain <code>              Explain an error code, e.g. `onyx explain E0200`",
        "  onyx version                     Print the version",
        "",
        "Options (before the file name):",
        "  --target js                      Compile to JavaScript and run with Node.js (default)",
        "  --target native                  Compile to a Linux x86-64 executable (experimental)",
        "  --target jvm                     Compile to a .jar and run it with Java (experimental)",
        "  --leak-check                     Native only: fail at exit if some memory was never released"
    ].join("\n")
}

// The version, as Cargo.toml gives it to both compilers.
const CARGO = embed("../Cargo.toml")

fn version() -> string {
    for line in CARGO.split("\n") {
        if line.starts_with("version = \"") {
            return line.split("\"")[1]
        }
    }
    return "?"
}

fn die(message: string) {
    eprint("error: " + message)
    exit(2)
}

// A reason for a failed file operation, as Rust's `io::Error` words it.
fn io_error(message: string) -> string {
    var parts = message.split(": ")
    var reason = parts[parts.len() - 1]
    var known = {
        "no such file or directory": "No such file or directory (os error 2)",
        "permission denied": "Permission denied (os error 13)",
        "is a directory": "Is a directory (os error 21)",
        "not a directory": "Not a directory (os error 20)",
        "no space left on device": "No space left on device (os error 28)",
        "file exists": "File exists (os error 17)"
    }
    if known.has(reason) {
        return known[reason]
    }
    return reason
}

// ---- paths ----

// The last part of a path.
fn file_name(path: string) -> string {
    var parts = path.split("/")
    return parts[parts.len() - 1]
}

// The name of a file without its last extension: `a.test` for `a.test.ox`.
fn file_stem(path: string) -> string {
    var name = file_name(path)
    var dot = -1
    for i in 1..name.len() {
        if name[i] == "." {
            dot = i
        }
    }
    if dot < 0 {
        return name
    }
    return name.slice(0, dot)
}

// `path` with its last part replaced by `name`.
fn with_file_name(path: string, name: string) -> string {
    var parts = path.split("/")
    if parts.len() == 1 {
        return name
    }
    parts[parts.len() - 1] = name
    return parts.join("/")
}

fn join_path(dir: string, name: string) -> string {
    if dir.ends_with("/") {
        return dir + name
    }
    return dir + "/" + name
}

fn is_file(path: string) -> bool {
    return file_exists(path) && !is_dir(path)
}

// `name.test.ox` for `name.ox`, if that file exists ("" otherwise).
fn test_file_of(path: string) -> string {
    var name = file_name(path)
    if !name.ends_with(".ox") || name.ends_with(".test.ox") {
        return ""
    }
    var candidate = with_file_name(path, name.slice(0, name.len() - 3) + ".test.ox")
    if is_file(candidate) {
        return candidate
    }
    return ""
}

// The file that `name.test.ox` tests, if it exists ("" otherwise).
fn tested_file_of(path: string) -> string {
    var name = file_name(path)
    if !name.ends_with(".test.ox") {
        return ""
    }
    var candidate = with_file_name(path, name.slice(0, name.len() - 8) + ".ox")
    if is_file(candidate) {
        return candidate
    }
    return ""
}

// ---- compiling ----

// What the compiler produced: JavaScript, an executable, or a jar.
struct Output {
    target: string
    js: string
    binary: [int]
}

// The runtime a target adds to the program.
fn runtime_of(target: string) -> string {
    if target == "js" {
        return ""
    }
    return target
}

// The extension of what `build` writes.
fn extension_of(target: string) -> string {
    if target == "js" {
        return ".js"
    }
    if target == "jvm" {
        return ".jar"
    }
    return ""
}

// Shows the problems and stops.
fn report_errors(report: diag.Report, sources: modules.Sources, file: string, color: bool) {
    for d in report.diags {
        eprint(errors.render(d, sources, color))
    }
    var n = report.diags.len()
    var plural = "s"
    if n == 1 {
        plural = ""
    }
    eprint("error: could not compile `" + file + "` (" + str(n) + " error" + plural + ")")
    exit(1)
}

// Compiles a source file, showing the problems and exiting when there are some.
fn compile(path: string, test_mode: bool, target: string, leak_check: bool) -> Output {
    // The tests of `name.ox` may live next to it, in `name.test.ox`.
    var companion = ""
    if test_mode {
        companion = test_file_of(path)
    }
    // Colors on a terminal, unless NO_COLOR is set.
    var color = stderr_is_terminal()
    var no_color = true
    env("NO_COLOR") catch err {
        no_color = false
    }
    if no_color {
        color = false
    }
    for file in [path, companion] {
        if file != "" {
            read_bytes(file) catch err {
                die("cannot read `" + file + "`: " + io_error(err.message))
            }
        }
    }
    var sources = modules.new_sources()
    var report = diag.new_report()
    var linked = modules.load_with(path, runtime_of(target), companion, sources, report) catch err {
        if err.message.starts_with("fatal") {
            die("cannot read `" + path + "`")
        }
        report_errors(report, sources, path, color)
        return Output{target: target, js: "", binary: []}
    }
    var program = linked.program
    var an = checker.check(program, sources.bytes, !test_mode, linked.runtime_start, linked.runtime_end, report) catch err {
        report_errors(report, sources, path, color)
        return Output{target: target, js: "", binary: []}
    }
    desugar.desugar(program, an)
    optimize.optimize(program)
    if target == "js" {
        return Output{target: target, js: js.generate(program, an, sources, test_mode), binary: []}
    }
    if target == "jvm" {
        widen.widen(program, an)
        capture.capture(program, an)
        lower.lower_for(program, an, true)
        var archive = jvm.generate(program, an, test_mode, sources, report) catch err {
            report_errors(report, sources, path, color)
            return Output{target: target, js: "", binary: []}
        }
        return Output{target: target, js: "", binary: archive}
    }
    widen.widen(program, an)
    capture.capture(program, an)
    lower.lower(program, an)
    var executable = gen.generate(program, an, leak_check, test_mode, sources, report) catch err {
        report_errors(report, sources, path, color)
        return Output{target: target, js: "", binary: []}
    }
    return Output{target: target, js: "", binary: executable}
}

fn write_output(path: string, output: Output) {
    if output.target == "native" {
        write_bytes(path, output.binary) catch err {
            die("cannot write `" + path + "`: " + io_error(err.message))
        }
        set_executable(path) catch err {
            die("cannot write `" + path + "`: " + io_error(err.message))
        }
    } else if output.target == "jvm" {
        write_bytes(path, output.binary) catch err {
            die("cannot write `" + path + "`: " + io_error(err.message))
        }
    } else {
        write_file(path, output.js) catch err {
            die("cannot write `" + path + "`: " + io_error(err.message))
        }
    }
}

// ---- options ----

struct Options {
    // "js", "native" or "jvm".
    target: string
    leak_check: bool
    // What follows the options.
    rest: [string]
}

// Removes the leading options (`--target <name>`, `--leak-check`) from the arguments.
fn take_options(arguments: [string]) -> Options {
    var options = Options{target: "js", leak_check: false, rest: []}
    var i = 0
    while i < arguments.len() {
        if arguments[i] == "--target" {
            if i + 1 >= arguments.len() {
                die("`--target` needs a value (available: js, native, jvm)")
            }
            var target = arguments[i + 1]
            if target == "js" || target == "native" || target == "jvm" {
                options.target = target
            } else {
                die("unknown target `" + target + "` (available: js, native, jvm)")
            }
            i += 2
        } else if arguments[i] == "--leak-check" {
            options.leak_check = true
            i += 1
        } else {
            break
        }
    }
    options.rest = arguments.slice(i, arguments.len())
    return options
}

fn source_arg(arguments: [string]) -> string {
    if arguments.len() == 0 {
        die("missing source file, e.g. `onyx run main.ox`")
    }
    return arguments[0]
}

// ---- running ----

// The exit code of a program that ended, with the shell convention 128 +
// signal when it was killed.
fn exit_code(status: int) -> int {
    if status >= 0 {
        return status
    }
    var signal = -status
    // 13 is SIGPIPE: the reader of the output went away (`... | head`).
    if signal != 13 {
        eprint("fatal: the program was killed by signal " + str(signal))
    }
    return 128 + signal
}

// Compiles and runs a file; returns the exit code of the program.
fn execute(file: string, test_mode: bool, options: Options, arguments: [string]) -> int {
    var output = compile(file, test_mode, options.target, options.leak_check)
    var dir = env("TMPDIR") or "/tmp"
    var tmp = join_path(dir, "onyx-" + str(now()) + "-" + str(random_int(0, 999999)) + "-" + file_stem(file) + extension_of(output.target))
    write_output(tmp, output)
    var status = 0
    if output.target == "jvm" {
        var java_args = ["-jar", tmp]
        for a in arguments {
            java_args.push(a)
        }
        status = run_program("java", java_args) catch err {
            remove_file(tmp) catch e {
            }
            die("Onyx needs Java to run programs on the JVM target, but `java` was not found.\nInstall a Java runtime (version 11 or later) or use `onyx build` to only produce the .jar file.")
            return 2
        }
    } else if output.target == "native" {
        status = run_program(tmp, arguments) catch err {
            remove_file(tmp) catch e {
            }
            die("cannot run the compiled program: " + io_error(err.message))
            return 2
        }
    } else {
        var node_args = [tmp]
        for a in arguments {
            node_args.push(a)
        }
        status = run_program("node", node_args) catch err {
            remove_file(tmp) catch e {
            }
            die("Onyx needs Node.js to run programs, but `node` was not found.\nInstall it from https://nodejs.org or use `onyx build` to only produce the .js file.")
            return 2
        }
    }
    remove_file(tmp) catch err {
    }
    return exit_code(status)
}

fn run(arguments: [string], test_mode: bool) {
    var options = take_options(arguments)
    var file = source_arg(options.rest)
    exit(execute(file, test_mode, options, options.rest.slice(1, options.rest.len())))
}

fn build(arguments: [string]) {
    var options = take_options(arguments)
    var file = source_arg(options.rest)
    var out = ""
    var rest = options.rest
    var i = 1
    while i < rest.len() {
        if rest[i] == "-o" || rest[i] == "--out" {
            if i + 1 >= rest.len() {
                die("`-o` needs a file name")
            }
            out = rest[i + 1]
            i += 2
        } else {
            die("unknown option `" + rest[i] + "`")
        }
    }
    var output = compile(file, false, options.target, options.leak_check)
    if out == "" {
        out = "build/" + file_stem(file) + extension_of(output.target)
    }
    var parts = out.split("/")
    if parts.len() > 1 {
        var dir = parts.slice(0, parts.len() - 1).join("/")
        if dir != "" {
            make_dir(dir) catch err {
                die("cannot create `" + dir + "`: " + io_error(err.message))
            }
        }
    }
    write_output(out, output)
    print("built " + file + " -> " + out)
}

// ---- tests ----

// The files of a folder (and of the folders inside it) that have tests:
// those with a `name.test.ox` next to them, test files on their own, and
// those that contain `check` blocks.
fn find_tests(dir: string, found: [string]) {
    var names = list_dir(dir) catch err {
        return
    }
    for name in names {
        var path = join_path(dir, name)
        if is_dir(path) {
            if !name.starts_with(".") && name != "target" && name != "build" && name != "node_modules" {
                find_tests(path, found)
            }
        } else if name.ends_with(".test.ox") {
            // Reported under the file it tests, when there is one.
            if tested_file_of(path) == "" {
                found.push(path)
            }
        } else if name.ends_with(".ox") {
            var text = read_file(path) or ""
            var has_checks = false
            for line in text.split("\n") {
                if line.starts_with("check \"") {
                    has_checks = true
                }
            }
            if has_checks || test_file_of(path) != "" {
                found.push(path)
            }
        }
    }
}

fn test(arguments: [string]) {
    var options = take_options(arguments)
    var given = "."
    if options.rest.len() > 0 {
        given = options.rest[0]
    }
    if !is_dir(given) {
        // One file: `name.ox`, or its `name.test.ox`, which is the same thing.
        var file = tested_file_of(given)
        if file == "" {
            file = given
        }
        exit(execute(file, true, options, []))
    }
    var files: [string] = []
    find_tests(given, files)
    if files.len() == 0 {
        print("no tests found in `" + given + "` (tests are `check` blocks, in `name.ox` or in `name.test.ox`)")
        return
    }
    var target = options.target
    var failed = 0
    for file in files {
        var shown = file
        if shown.starts_with("./") {
            shown = shown.slice(2, shown.len())
        }
        print(shown)
        // Each file is tested by a compiler of its own, so that one that
        // does not compile does not stop the others.
        var status = run_program("/proc/self/exe", ["test", "--target", target, file]) or -1
        if status != 0 {
            failed += 1
        }
        print("")
    }
    var plural = "s"
    if files.len() == 1 {
        plural = ""
    }
    print(str(files.len()) + " file" + plural + " tested, " + str(failed) + " with failures")
    if failed > 0 {
        exit(1)
    }
    exit(0)
}

fn explain(arguments: [string]) {
    if arguments.len() == 0 {
        die("missing error code, e.g. `onyx explain E0200`")
    }
    var code = arguments[0].upper()
    for text in errors.explain(code) {
        print(code + "\n\n" + text)
        return
    }
    die("unknown error code `" + code + "`")
}

fn main() -> void! {
    var arguments = args()
    if arguments.len() == 0 {
        print(usage())
        return
    }
    var command = arguments[0]
    var rest = arguments.slice(1, arguments.len())
    if command == "run" {
        run(rest, false)
    } else if command == "test" {
        test(rest)
    } else if command == "build" {
        build(rest)
    } else if command == "check" {
        var options = take_options(rest)
        var file = source_arg(options.rest)
        compile(file, false, options.target, false)
        print("ok: " + file + " has no errors")
    } else if command == "tokens" {
        // What each stage makes of a file, to compare with the compiler
        // written in Rust.
        stages.dump_tokens(source_arg(rest))?
    } else if command == "ast" {
        stages.dump_ast(source_arg(rest))?
    } else if command == "modules" {
        stages.dump_modules(source_arg(rest))
    } else if command == "types" {
        stages.dump_types(source_arg(rest))
    } else if command == "lowered" {
        stages.dump_lowered(source_arg(rest))
    } else if command == "explain" {
        explain(rest)
    } else if command == "version" || command == "--version" || command == "-V" {
        print("onyx " + version())
    } else if command == "help" || command == "--help" || command == "-h" {
        print(usage())
    } else if command.ends_with(".ox") {
        run(arguments, false)
    } else {
        die("unknown command `" + command + "`\n\n" + usage())
    }
}
