//! The `onyx` command-line tool.

mod ast;
mod checker;
mod codegen_js;
mod desugar;
mod dump;
mod diagnostics;
mod lexer;
mod modules;
mod native;
mod optimize;
mod parser;

use std::io::IsTerminal;
use std::path::{Path, PathBuf};
use std::process::{exit, Command};
use std::sync::atomic::{AtomicBool, Ordering};

const VERSION: &str = env!("CARGO_PKG_VERSION");

const USAGE: &str = "\
Onyx - a small, statically typed programming language

Usage:
  onyx run <file.ox> [args...]     Compile and run a program
  onyx build <file.ox> [-o <out>]  Compile to build/<name>.js, or build/<name> with --target native
  onyx check <file.ox>             Check a program for errors without running it
  onyx test [file.ox | folder]     Run the `check` blocks of a file and of its `name.test.ox`
                                   file; without a file, every test of the folder
  onyx explain <code>              Explain an error code, e.g. `onyx explain E0200`
  onyx version                     Print the version

Options (before the file name):
  --target js                      Compile to JavaScript and run with Node.js (default)
  --target native                  Compile to a Linux x86-64 executable (experimental)
  --leak-check                     Native only: fail at exit if some memory was never released";

#[derive(Clone, Copy, PartialEq)]
enum Target {
    Js,
    Native,
}

/// What the compiler produced.
enum Output {
    Js(String),
    Native(Vec<u8>),
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let Some(command) = args.first() else {
        println!("{USAGE}");
        return;
    };
    let rest = &args[1..];
    match command.as_str() {
        "run" => run(rest, false),
        "test" => test(rest),
        "build" => build(rest),
        "check" => {
            let (target, rest) = take_target(rest);
            let file = source_arg(&rest);
            compile(&file, false, target);
            println!("ok: {} has no errors", file.display());
        }
        // For the compiler written in Onyx (see compiler/): what the lexer
        // makes of a file, in a form that the two can be compared on.
        "tokens" => dump_tokens(&source_arg(rest)),
        "ast" => dump_ast(&source_arg(rest)),
        "modules" => dump_modules(&source_arg(rest)),
        "types" => dump_types(&source_arg(rest)),
        "lowered" => dump_lowered(&source_arg(rest)),
        "explain" => explain(rest),
        "version" | "--version" | "-V" => println!("onyx {VERSION}"),
        "help" | "--help" | "-h" => println!("{USAGE}"),
        other if other.ends_with(".ox") => run(&args, false),
        other => die(&format!("unknown command `{other}`\n\n{USAGE}")),
    }
}

fn dump_ast(path: &Path) {
    let text = std::fs::read_to_string(path).unwrap_or_else(|e| die(&format!("cannot read `{}`: {e}", path.display())));
    match parser::parse(&text, 0, text.len(), 0) {
        Ok((program, _)) => {
            let mut dump = dump::Dump::new(&text);
            dump.program(&program);
            print!("{}", dump.out);
        }
        Err(d) => println!("error {} {} {} {}", d.code, d.span.start, d.span.end, d.message),
    }
}

/// The program once its files are linked into one (stage 3 of the compiler
/// written in Onyx is compared on this).
fn dump_modules(path: &Path) {
    let mut sources = diagnostics::SourceMap::default();
    match modules::load(path, &mut sources, None, None) {
        Ok((program, _)) => {
            let mut dump = dump::Dump::new(&sources.text);
            dump.program(&program);
            print!("{}", dump.out);
        }
        Err(Ok(diags)) => {
            for d in diags {
                println!("error {} {} {} {}", d.code, d.span.start, d.span.end, d.message);
            }
        }
        Err(Err(_)) => println!("fatal"),
    }
}

/// A problem, in full, for the comparisons with the compiler written in Onyx.
fn dump_diag(d: &diagnostics::Diagnostic) {
    println!("error {} {}:{} {}", d.code, d.span.start, d.span.end, d.message);
    if !d.label.is_empty() {
        println!("  label: {}", d.label);
    }
    if let Some(help) = &d.help {
        println!("  help: {help}");
    }
}

/// What the type checker learns about a program (stage 4 of the compiler
/// written in Onyx is compared on this).
fn dump_types(path: &Path) {
    let mut sources = diagnostics::SourceMap::default();
    let program = match modules::load(path, &mut sources, None, None) {
        Ok((program, _)) => program,
        Err(Ok(diags)) => return diags.iter().for_each(dump_diag),
        Err(Err(_)) => return println!("fatal"),
    };
    match checker::check(&program, &sources.text, true, None) {
        Ok(analysis) => print!("{}", checker::dump(&analysis)),
        Err(diags) => diags.iter().for_each(dump_diag),
    }
}

/// The program as the native code generator receives it, the runtime
/// included, after the passes that prepare it (stage 5 of the compiler
/// written in Onyx is compared on this).
fn dump_lowered(path: &Path) {
    let mut sources = diagnostics::SourceMap::default();
    let prelude = Some(("<onyx runtime>", native::RUNTIME_SOURCE));
    let (mut program, runtime) = match modules::load(path, &mut sources, prelude, None) {
        Ok(loaded) => loaded,
        Err(Ok(diags)) => return diags.iter().for_each(dump_diag),
        Err(Err(_)) => return println!("fatal"),
    };
    let mut analysis = match checker::check(&program, &sources.text, true, runtime) {
        Ok(analysis) => analysis,
        Err(diags) => return diags.iter().for_each(dump_diag),
    };
    desugar::desugar(&mut program, &mut analysis);
    optimize::optimize(&mut program);
    native::prepare(&mut program, &mut analysis);
    let mut dump = dump::Dump::new(&sources.text);
    dump.ids = true;
    dump.program(&program);
    print!("{}", dump.out);
    print!("{}", checker::dump(&analysis));
    let mut lambdas: Vec<&usize> = analysis.captures.keys().collect();
    lambdas.sort();
    for id in lambdas {
        let captured: Vec<String> = analysis.captures[id].iter().map(|(name, ty)| format!("{name}: {ty}")).collect();
        println!("captures {id} {}", captured.join(", "));
    }
    println!("forks {}", analysis.has_forks);
}

fn dump_tokens(path: &Path) {
    let text = std::fs::read_to_string(path).unwrap_or_else(|e| die(&format!("cannot read `{}`: {e}", path.display())));
    let quote = |s: &str| {
        let mut out = String::from("\"");
        for c in s.chars() {
            match c {
                '\\' => out.push_str("\\\\"),
                '"' => out.push_str("\\\""),
                '\n' => out.push_str("\\n"),
                '\t' => out.push_str("\\t"),
                '\r' => out.push_str("\\r"),
                '\0' => out.push_str("\\0"),
                other => out.push(other),
            }
        }
        out.push('"');
        out
    };
    let mut out = String::new();
    match lexer::lex(&text, 0, text.len()) {
        Ok(tokens) => {
            for t in tokens {
                let debug = format!("{:?}", t.tok);
                let name = debug.split(['(', ' ']).next().unwrap_or_default();
                out.push_str(&format!("{} {} {} {name}", t.span.start, t.span.end, t.nl_before as u8));
                match &t.tok {
                    lexer::Tok::Int(n) => out.push_str(&format!(" {n}")),
                    lexer::Tok::Float(_) => out.push_str(&format!(" {}", &text[t.span.start..t.span.end])),
                    lexer::Tok::Ident(word) => out.push_str(&format!(" {word}")),
                    lexer::Tok::Str(pieces) => {
                        for piece in pieces {
                            match piece {
                                lexer::StrPiece::Lit(s) => out.push_str(&format!(" L{}", quote(s))),
                                lexer::StrPiece::Code { start, end } => out.push_str(&format!(" C{start}:{end}")),
                            }
                        }
                    }
                    _ => {}
                }
                out.push('\n');
            }
        }
        Err(d) => out.push_str(&format!("error {} {} {} {}\n", d.code, d.span.start, d.span.end, d.message)),
    }
    print!("{out}");
}

fn die(message: &str) -> ! {
    eprintln!("error: {message}");
    exit(2);
}

fn source_arg(args: &[String]) -> PathBuf {
    match args.first() {
        Some(file) => PathBuf::from(file),
        None => die("missing source file, e.g. `onyx run main.ox`"),
    }
}

/// Set by `--leak-check`: native programs verify at exit that all memory was released.
static LEAK_CHECK: AtomicBool = AtomicBool::new(false);

/// Removes the leading options (`--target <name>`, `--leak-check`) from the arguments.
fn take_target(args: &[String]) -> (Target, Vec<String>) {
    let mut target = Target::Js;
    let mut i = 0;
    loop {
        match args.get(i).map(String::as_str) {
            Some("--target") => {
                target = match args.get(i + 1).map(String::as_str) {
                    Some("js") => Target::Js,
                    Some("native") => Target::Native,
                    Some("jvm") => die("the JVM target is not implemented yet"),
                    Some(other) => die(&format!("unknown target `{other}` (available: js, native)")),
                    None => die("`--target` needs a value (available: js, native)"),
                };
                i += 2;
            }
            Some("--leak-check") => {
                LEAK_CHECK.store(true, Ordering::Relaxed);
                i += 1;
            }
            _ => return (target, args[i..].to_vec()),
        }
    }
}

/// Compiles a source file, printing diagnostics and exiting on error.
fn compile(path: &Path, test_mode: bool, target: Target) -> Output {
    // The tests of `name.ox` may live next to it, in `name.test.ox`.
    let companion = test_mode.then(|| test_file_of(path)).flatten();
    let file = path.to_string_lossy();
    let color = std::io::stderr().is_terminal() && std::env::var_os("NO_COLOR").is_none();
    let mut sources = diagnostics::SourceMap::default();
    let prelude = (target == Target::Native).then_some(("<onyx runtime>", native::RUNTIME_SOURCE));
    let loaded = modules::load(path, &mut sources, prelude, companion.as_deref());
    let report = |diags: &[diagnostics::Diagnostic]| -> ! {
        for d in diags {
            eprintln!("{}", diagnostics::render(d, &sources, color));
        }
        let n = diags.len();
        eprintln!("error: could not compile `{file}` ({n} error{})", if n == 1 { "" } else { "s" });
        exit(1);
    };
    let (mut program, runtime) = match loaded {
        Ok(loaded) => loaded,
        Err(Ok(diags)) => report(&diags),
        Err(Err(message)) => die(&message),
    };
    let mut analysis = match checker::check(&program, &sources.text, !test_mode, runtime) {
        Ok(analysis) => analysis,
        Err(diags) => report(&diags),
    };
    desugar::desugar(&mut program, &mut analysis);
    optimize::optimize(&mut program);
    match target {
        Target::Js => Output::Js(codegen_js::generate(
            &program,
            &analysis,
            &codegen_js::Options { sources: &sources, test_mode },
        )),
        Target::Native => match native::generate(
            &mut program,
            &mut analysis,
            LEAK_CHECK.load(Ordering::Relaxed),
            test_mode.then_some(&sources),
        ) {
            Ok(bytes) => Output::Native(bytes),
            Err(diags) => report(&diags),
        },
    }
}

fn write_output(path: &Path, output: &Output) {
    let result = match output {
        Output::Js(js) => std::fs::write(path, js),
        Output::Native(bytes) => std::fs::write(path, bytes).and_then(|_| make_executable(path)),
    };
    if let Err(e) = result {
        die(&format!("cannot write `{}`: {e}", path.display()));
    }
}

#[cfg(unix)]
fn make_executable(path: &Path) -> std::io::Result<()> {
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755))
}

#[cfg(not(unix))]
fn make_executable(_path: &Path) -> std::io::Result<()> {
    Ok(())
}

fn stem_of(file: &Path) -> String {
    file.file_stem().map(|s| s.to_string_lossy().to_string()).unwrap_or_default()
}

/// `name.test.ox` for `name.ox`, if that file exists.
fn test_file_of(path: &Path) -> Option<PathBuf> {
    let name = path.file_name()?.to_str()?;
    let stem = name.strip_suffix(".ox")?;
    if stem.ends_with(".test") {
        return None;
    }
    let candidate = path.with_file_name(format!("{stem}.test.ox"));
    candidate.is_file().then_some(candidate)
}

/// The file that `name.test.ox` tests, if it exists.
fn tested_file_of(path: &Path) -> Option<PathBuf> {
    let name = path.file_name()?.to_str()?;
    let stem = name.strip_suffix(".test.ox")?;
    let candidate = path.with_file_name(format!("{stem}.ox"));
    candidate.is_file().then_some(candidate)
}

/// The files of a folder (and of the folders inside it) that have tests:
/// those with a `name.test.ox` next to them, test files on their own, and
/// those that contain `check` blocks.
fn find_tests(dir: &Path, found: &mut Vec<PathBuf>) {
    let Ok(entries) = std::fs::read_dir(dir) else { return };
    let mut paths: Vec<PathBuf> = entries.flatten().map(|e| e.path()).collect();
    paths.sort();
    for path in paths {
        let name = path.file_name().and_then(|n| n.to_str()).unwrap_or_default().to_string();
        if path.is_dir() {
            if !name.starts_with('.') && !matches!(name.as_str(), "target" | "build" | "node_modules") {
                find_tests(&path, found);
            }
        } else if name.ends_with(".test.ox") {
            // Reported under the file it tests, when there is one.
            if tested_file_of(&path).is_none() {
                found.push(path);
            }
        } else if name.ends_with(".ox") {
            let has_checks = std::fs::read_to_string(&path)
                .is_ok_and(|text| text.lines().any(|line| line.starts_with("check \"")));
            if has_checks || test_file_of(&path).is_some() {
                found.push(path);
            }
        }
    }
}

fn test(args: &[String]) {
    let (target, args) = take_target(args);
    let given = args.first().map(PathBuf::from).unwrap_or_else(|| PathBuf::from("."));
    if !given.is_dir() {
        // One file: `name.ox`, or its `name.test.ox`, which is the same thing.
        let file = tested_file_of(&given).unwrap_or(given);
        exit(execute(&file, true, target, &[]));
    }
    let mut files = Vec::new();
    find_tests(&given, &mut files);
    if files.is_empty() {
        println!("no tests found in `{}` (tests are `check` blocks, in `name.ox` or in `name.test.ox`)", given.display());
        return;
    }
    let mut failed = 0;
    for file in &files {
        println!("{}", file.strip_prefix("./").unwrap_or(file).display());
        // Each file is tested by a compiler of its own, so that one that
        // does not compile does not stop the others.
        use std::io::Write;
        let _ = std::io::stdout().flush();
        let name = if target == Target::Native { "native" } else { "js" };
        let status = std::env::current_exe()
            .and_then(|onyx| Command::new(onyx).args(["test", "--target", name]).arg(file).status());
        if !status.is_ok_and(|s| s.success()) {
            failed += 1;
        }
        println!();
    }
    let plural = |n: usize| if n == 1 { "" } else { "s" };
    println!("{} file{} tested, {} with failures", files.len(), plural(files.len()), failed);
    exit(if failed > 0 { 1 } else { 0 });
}

fn run(args: &[String], test_mode: bool) {
    let (target, args) = take_target(args);
    let file = source_arg(&args);
    exit(execute(&file, test_mode, target, &args[1..]));
}

/// Compiles and runs a file; returns the exit code of the program.
fn execute(file: &Path, test_mode: bool, target: Target, args: &[String]) -> i32 {
    let output = compile(file, test_mode, target);
    let extension = if target == Target::Js { ".js" } else { "" };
    let tmp = std::env::temp_dir().join(format!("onyx-{}-{}{extension}", std::process::id(), stem_of(file)));
    write_output(&tmp, &output);
    // What was printed so far must come before what the program prints.
    use std::io::Write;
    let _ = std::io::stdout().flush();
    let status = match target {
        Target::Js => Command::new("node").arg(&tmp).args(args).status(),
        Target::Native => Command::new(&tmp).args(args).status(),
    };
    let _ = std::fs::remove_file(&tmp);
    match status {
        Ok(status) => exit_code(status),
        Err(e) if target == Target::Native => die(&format!("cannot run the compiled program: {e}")),
        Err(_) => die("Onyx needs Node.js to run programs, but `node` was not found.\nInstall it from https://nodejs.org or use `onyx build` to only produce the .js file."),
    }
}

/// The exit code of a child, with the shell convention 128 + signal when it was killed.
fn exit_code(status: std::process::ExitStatus) -> i32 {
    if let Some(code) = status.code() {
        return code;
    }
    #[cfg(unix)]
    {
        use std::os::unix::process::ExitStatusExt;
        if let Some(signal) = status.signal() {
            // 13 is SIGPIPE: the reader of the output went away (`... | head`).
            if signal != 13 {
                eprintln!("fatal: the program was killed by signal {signal}");
            }
            return 128 + signal;
        }
    }
    2
}

fn build(args: &[String]) {
    let (target, args) = take_target(args);
    let file = source_arg(&args);
    let mut out: Option<PathBuf> = None;
    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "-o" | "--out" => {
                out = Some(PathBuf::from(args.get(i + 1).unwrap_or_else(|| die("`-o` needs a file name"))));
                i += 2;
            }
            other => die(&format!("unknown option `{other}`")),
        }
    }
    let output = compile(&file, false, target);
    let out = out.unwrap_or_else(|| {
        let extension = if target == Target::Js { ".js" } else { "" };
        Path::new("build").join(format!("{}{extension}", stem_of(&file)))
    });
    if let Some(dir) = out.parent() {
        if !dir.as_os_str().is_empty() {
            if let Err(e) = std::fs::create_dir_all(dir) {
                die(&format!("cannot create `{}`: {e}", dir.display()));
            }
        }
    }
    write_output(&out, &output);
    println!("built {} -> {}", file.display(), out.display());
}

fn explain(args: &[String]) {
    let Some(code) = args.first() else { die("missing error code, e.g. `onyx explain E0200`") };
    let code = code.to_uppercase();
    match diagnostics::explain(&code) {
        Some(text) => println!("{code}\n\n{text}"),
        None => die(&format!("unknown error code `{code}`")),
    }
}
