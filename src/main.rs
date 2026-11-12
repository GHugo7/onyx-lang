//! The `onyx` command-line tool.

mod ast;
mod checker;
mod codegen_js;
mod diagnostics;
mod lexer;
mod parser;

use std::io::IsTerminal;
use std::path::{Path, PathBuf};
use std::process::{exit, Command};

const VERSION: &str = env!("CARGO_PKG_VERSION");

const USAGE: &str = "\
Onyx - a small, statically typed programming language

Usage:
  onyx run <file.ox> [args...]     Compile and run a program
  onyx build <file.ox> [-o <out>]  Compile to JavaScript (default: build/<name>.js)
  onyx check <file.ox>             Check a program for errors without running it
  onyx test <file.ox>              Run the `check` blocks of a file
  onyx explain <code>              Explain an error code, e.g. `onyx explain E0200`
  onyx version                     Print the version

Options:
  --target js                      Compilation target (only `js` for now)";

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
            let file = source_arg(rest);
            compile(&file, false);
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

/// Compiles a source file to JavaScript, printing diagnostics and exiting on error.
fn compile(path: &Path, test_mode: bool) -> String {
    let src = match std::fs::read_to_string(path) {
        Ok(src) => src,
        Err(e) => die(&format!("cannot read `{}`: {e}", path.display())),
    };
    let file = path.to_string_lossy();
    let color = std::io::stderr().is_terminal() && std::env::var_os("NO_COLOR").is_none();
    let report = |diags: &[diagnostics::Diagnostic]| -> ! {
        for d in diags {
            eprintln!("{}", diagnostics::render(d, &file, &src, color));
        }
        let n = diags.len();
        eprintln!("error: could not compile `{file}` ({n} error{})", if n == 1 { "" } else { "s" });
        exit(1);
    };
    let program = match parser::parse(&src) {
        Ok(program) => program,
        Err(d) => report(&[d]),
    };
    let analysis = match checker::check(&program, &src, !test_mode) {
        Ok(analysis) => analysis,
        Err(diags) => report(&diags),
    };
    let name = path.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
    codegen_js::generate(&program, &analysis, &codegen_js::Options { file: &name, src: &src, test_mode })
}

fn check_target(args: &[String]) -> Vec<String> {
    let mut rest = Vec::new();
    let mut i = 0;
    while i < args.len() {
        if args[i] == "--target" {
            match args.get(i + 1).map(|s| s.as_str()) {
                Some("js") => {}
                Some("jvm") => die("the JVM target is not implemented yet; it is next on the roadmap"),
                Some(other) => die(&format!("unknown target `{other}` (available: js)")),
                None => die("`--target` needs a value (available: js)"),
            }
            i += 2;
        } else {
            rest.push(args[i].clone());
            i += 1;
        }
    }
    rest
}

fn run(args: &[String], test_mode: bool) {
    let file = source_arg(args);
    let js = compile(&file, test_mode);
    let stem = file.file_stem().map(|s| s.to_string_lossy().to_string()).unwrap_or_default();
    let tmp = std::env::temp_dir().join(format!("onyx-{}-{stem}.js", std::process::id()));
    if let Err(e) = std::fs::write(&tmp, js) {
        die(&format!("cannot write `{}`: {e}", tmp.display()));
    }
    let status = Command::new("node").arg(&tmp).args(&args[1..]).status();
    let _ = std::fs::remove_file(&tmp);
    match status {
        Ok(status) => exit(status.code().unwrap_or(2)),
        Err(_) => die("Onyx needs Node.js to run programs, but `node` was not found.\nInstall it from https://nodejs.org or use `onyx build` to only produce the .js file."),
    }
}

fn build(args: &[String]) {
    let args = check_target(args);
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
    let js = compile(&file, false);
    let out = out.unwrap_or_else(|| {
        let stem = file.file_stem().map(|s| s.to_string_lossy().to_string()).unwrap_or_default();
        Path::new("build").join(format!("{stem}.js"))
    });
    if let Some(dir) = out.parent() {
        if !dir.as_os_str().is_empty() {
            if let Err(e) = std::fs::create_dir_all(dir) {
                die(&format!("cannot create `{}`: {e}", dir.display()));
            }
        }
    }
    if let Err(e) = std::fs::write(&out, js) {
        die(&format!("cannot write `{}`: {e}", out.display()));
    }
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
