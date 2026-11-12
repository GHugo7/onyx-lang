//! The `onyx` command-line tool.

mod ast;
mod checker;
mod codegen_js;
mod diagnostics;
mod lexer;
mod modules;
mod native;
mod parser;

use std::io::IsTerminal;
use std::path::{Path, PathBuf};
use std::process::{exit, Command};

const VERSION: &str = env!("CARGO_PKG_VERSION");

const USAGE: &str = "\
Onyx - a small, statically typed programming language

Usage:
  onyx run <file.ox> [args...]     Compile and run a program
  onyx build <file.ox> [-o <out>]  Compile to build/<name>.js, or build/<name> with --target native
  onyx check <file.ox>             Check a program for errors without running it
  onyx test <file.ox>              Run the `check` blocks of a file
  onyx explain <code>              Explain an error code, e.g. `onyx explain E0200`
  onyx version                     Print the version

Options (before the file name):
  --target js                      Compile to JavaScript and run with Node.js (default)
  --target native                  Compile to a Linux x86-64 executable (experimental)";

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
        "test" => run(rest, true),
        "build" => build(rest),
        "check" => {
            let (target, rest) = take_target(rest);
            let file = source_arg(&rest);
            compile(&file, false, target);
            println!("ok: {} has no errors", file.display());
        }
        "explain" => explain(rest),
        "version" | "--version" | "-V" => println!("onyx {VERSION}"),
        "help" | "--help" | "-h" => println!("{USAGE}"),
        other if other.ends_with(".ox") => run(&args, false),
        other => die(&format!("unknown command `{other}`\n\n{USAGE}")),
    }
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

/// Removes a leading `--target <name>` from the arguments.
fn take_target(args: &[String]) -> (Target, Vec<String>) {
    if args.first().map(String::as_str) != Some("--target") {
        return (Target::Js, args.to_vec());
    }
    let target = match args.get(1).map(String::as_str) {
        Some("js") => Target::Js,
        Some("native") => Target::Native,
        Some("jvm") => die("the JVM target is not implemented yet"),
        Some(other) => die(&format!("unknown target `{other}` (available: js, native)")),
        None => die("`--target` needs a value (available: js, native)"),
    };
    (target, args[2..].to_vec())
}

/// Compiles a source file, printing diagnostics and exiting on error.
fn compile(path: &Path, test_mode: bool, target: Target) -> Output {
    let file = path.to_string_lossy();
    let color = std::io::stderr().is_terminal() && std::env::var_os("NO_COLOR").is_none();
    let mut sources = diagnostics::SourceMap::default();
    let prelude = (target == Target::Native).then_some(("<onyx runtime>", native::RUNTIME_SOURCE));
    let loaded = modules::load(path, &mut sources, prelude);
    let report = |diags: &[diagnostics::Diagnostic]| -> ! {
        for d in diags {
            eprintln!("{}", diagnostics::render(d, &sources, color));
        }
        let n = diags.len();
        eprintln!("error: could not compile `{file}` ({n} error{})", if n == 1 { "" } else { "s" });
        exit(1);
    };
    let (program, runtime) = match loaded {
        Ok(loaded) => loaded,
        Err(Ok(diags)) => report(&diags),
        Err(Err(message)) => die(&message),
    };
    let analysis = match checker::check(&program, &sources.text, !test_mode, runtime) {
        Ok(analysis) => analysis,
        Err(diags) => report(&diags),
    };
    match target {
        Target::Js => Output::Js(codegen_js::generate(
            &program,
            &analysis,
            &codegen_js::Options { sources: &sources, test_mode },
        )),
        Target::Native => match native::generate(&program, &analysis) {
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

fn run(args: &[String], test_mode: bool) {
    let (target, args) = take_target(args);
    let file = source_arg(&args);
    if test_mode && target == Target::Native {
        die("`onyx test` does not support the native target yet");
    }
    let output = compile(&file, test_mode, target);
    let extension = if target == Target::Js { ".js" } else { "" };
    let tmp = std::env::temp_dir().join(format!("onyx-{}-{}{extension}", std::process::id(), stem_of(&file)));
    write_output(&tmp, &output);
    let status = match target {
        Target::Js => Command::new("node").arg(&tmp).args(&args[1..]).status(),
        Target::Native => Command::new(&tmp).args(&args[1..]).status(),
    };
    let _ = std::fs::remove_file(&tmp);
    match status {
        Ok(status) => exit(exit_code(status)),
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
            eprintln!("fatal: the program was killed by signal {signal}");
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
