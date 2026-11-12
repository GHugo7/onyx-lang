//! End-to-end tests: every program in `tests/run` must print exactly its `.out`
//! file, and every program in `tests/errors` must be rejected with the error
//! code named on its first line (`// error: E0200`).

use std::path::{Path, PathBuf};
use std::process::Command;

const ONYX: &str = env!("CARGO_BIN_EXE_onyx");

fn programs(dir: &str) -> Vec<PathBuf> {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join(dir);
    let mut files: Vec<PathBuf> = std::fs::read_dir(&root)
        .unwrap_or_else(|e| panic!("cannot read {}: {e}", root.display()))
        .map(|entry| entry.unwrap().path())
        .filter(|path| path.extension().is_some_and(|ext| ext == "ox"))
        .collect();
    files.sort();
    assert!(!files.is_empty(), "no programs found in {dir}");
    files
}

#[test]
fn run_programs_print_expected_output() {
    let mut failures = Vec::new();
    for file in programs("tests/run") {
        let expected = std::fs::read_to_string(file.with_extension("out")).unwrap();
        let output = Command::new(ONYX).arg("run").arg(&file).output().unwrap();
        let stdout = String::from_utf8_lossy(&output.stdout);
        if !output.status.success() || stdout != expected {
            failures.push(format!(
                "{}\n--- expected\n{expected}\n--- got\n{stdout}\n--- stderr\n{}",
                file.display(),
                String::from_utf8_lossy(&output.stderr)
            ));
        }
    }
    assert!(failures.is_empty(), "{}", failures.join("\n\n"));
}

#[test]
fn invalid_programs_are_rejected_with_the_right_code() {
    let mut failures = Vec::new();
    for file in programs("tests/errors") {
        let src = std::fs::read_to_string(&file).unwrap();
        let code = src.lines().next().unwrap().trim_start_matches("// error:").trim().to_string();
        let output = Command::new(ONYX).arg("check").arg(&file).output().unwrap();
        let stderr = String::from_utf8_lossy(&output.stderr);
        if output.status.code() != Some(1) || !stderr.contains(&format!("error[{code}]")) {
            failures.push(format!("{}: expected {code}, got\n{stderr}", file.display()));
        }
    }
    assert!(failures.is_empty(), "{}", failures.join("\n\n"));
}

#[test]
fn examples_compile_and_their_checks_pass() {
    let mut files = programs("examples");
    files.push(Path::new(env!("CARGO_MANIFEST_DIR")).join("examples/shop/main.ox"));
    for file in files {
        let output = Command::new(ONYX).arg("check").arg(&file).output().unwrap();
        assert!(output.status.success(), "{}: {}", file.display(), String::from_utf8_lossy(&output.stderr));
        let output = Command::new(ONYX).arg("test").arg(&file).output().unwrap();
        assert!(output.status.success(), "{}: {}", file.display(), String::from_utf8_lossy(&output.stdout));
    }
}

#[test]
fn runtime_failures_set_the_exit_code() {
    let dir = std::env::temp_dir().join(format!("onyx-suite-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let cases = [
        ("fn main() {\n    var xs = [1]\n    print(xs[3])\n}\n", 2, "panic: index out of bounds"),
        ("fn main() {\n    var z = 0\n    print(1 / z)\n}\n", 2, "panic: division by zero"),
        ("fn main() -> void! {\n    fail \"boom\"\n}\n", 1, "error: boom"),
        ("fn main() {\n    var ch = chan<int>()\n    print(<-ch)\n}\n", 2, "deadlock"),
        ("fn main() {\n    exit(7)\n}\n", 7, ""),
    ];
    for (i, (src, code, message)) in cases.iter().enumerate() {
        let file = dir.join(format!("case{i}.ox"));
        std::fs::write(&file, src).unwrap();
        let output = Command::new(ONYX).arg("run").arg(&file).output().unwrap();
        let stderr = String::from_utf8_lossy(&output.stderr);
        assert_eq!(output.status.code(), Some(*code), "case {i}: {stderr}");
        assert!(stderr.contains(message), "case {i}: {stderr}");
    }
    let _ = std::fs::remove_dir_all(&dir);
}

/// Every complete program (one with a `main`) inside an ```onyx block of the
/// README or the docs must type-check.
#[test]
fn documentation_examples_compile() {
    fn markdown_files(dir: &Path, out: &mut Vec<PathBuf>) {
        for entry in std::fs::read_dir(dir).unwrap() {
            let path = entry.unwrap().path();
            if path.is_dir() {
                markdown_files(&path, out);
            } else if path.extension().is_some_and(|ext| ext == "md") {
                out.push(path);
            }
        }
    }
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let mut files = vec![root.join("README.md")];
    markdown_files(&root.join("docs"), &mut files);

    let dir = std::env::temp_dir().join(format!("onyx-docs-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let mut checked = 0;
    let mut failures = Vec::new();
    for file in files {
        let text = std::fs::read_to_string(&file).unwrap();
        for (i, block) in text.split("```onyx\n").skip(1).enumerate() {
            let code = block.split("```").next().unwrap();
            // Only complete, single-file programs can be checked on their own.
            if !code.contains("fn main(") || code.contains("import \"") {
                continue;
            }
            let path = dir.join(format!("snippet{checked}.ox"));
            std::fs::write(&path, code).unwrap();
            let output = Command::new(ONYX).arg("check").arg(&path).output().unwrap();
            if !output.status.success() {
                failures.push(format!(
                    "{} (onyx block #{}):\n{}",
                    file.display(),
                    i + 1,
                    String::from_utf8_lossy(&output.stderr)
                ));
            }
            checked += 1;
        }
    }
    let _ = std::fs::remove_dir_all(&dir);
    assert!(checked > 10, "expected to find documentation examples, found {checked}");
    assert!(failures.is_empty(), "{}", failures.join("\n\n"));
}

/// The native target writes Linux x86-64 executables, so these tests only run there.
#[cfg(all(target_os = "linux", target_arch = "x86_64"))]
mod native {
    use super::*;

    fn run_source(name: &str, src: &str) -> std::process::Output {
        let dir = std::env::temp_dir().join(format!("onyx-native-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join(name);
        std::fs::write(&file, src).unwrap();
        Command::new(ONYX).args(["run", "--target", "native"]).arg(&file).output().unwrap()
    }

    /// Native programs must print their `.out` file, and exactly what the
    /// JavaScript target prints for the same source.
    #[test]
    fn native_and_javascript_agree() {
        for file in programs("tests/native") {
            let expected = std::fs::read_to_string(file.with_extension("out")).unwrap();
            let native = Command::new(ONYX).args(["run", "--target", "native"]).arg(&file).output().unwrap();
            let js = Command::new(ONYX).arg("run").arg(&file).output().unwrap();
            assert!(native.status.success(), "{}: {}", file.display(), String::from_utf8_lossy(&native.stderr));
            assert_eq!(String::from_utf8_lossy(&native.stdout), expected, "{}", file.display());
            assert_eq!(String::from_utf8_lossy(&js.stdout), expected, "{} on the JavaScript target", file.display());
        }
    }

    #[test]
    fn integers_are_64_bits() {
        let out = run_source(
            "big.ox",
            "fn main() {\n    var min = -9223372036854775807 - 1\n    print(9223372036854775807, min, min / -1, min % -1)\n}\n",
        );
        assert_eq!(
            String::from_utf8_lossy(&out.stdout),
            "9223372036854775807 -9223372036854775808 -9223372036854775808 0\n"
        );
    }

    #[test]
    fn failures_set_the_exit_code() {
        let out = run_source("zero.ox", "fn main() {\n    var z = 0\n    print(1 / z)\n}\n");
        assert_eq!(out.status.code(), Some(2));
        assert_eq!(String::from_utf8_lossy(&out.stderr), "panic: division by zero\n");

        let out = run_source("exit.ox", "fn main() {\n    print(\"before\")\n    exit(7)\n    print(\"after\")\n}\n");
        assert_eq!(out.status.code(), Some(7));
        assert_eq!(String::from_utf8_lossy(&out.stdout), "before\n");

        let out = run_source("panic.ox", "fn main() {\n    panic(\"oops\")\n}\n");
        assert_eq!(out.status.code(), Some(2));
        assert_eq!(String::from_utf8_lossy(&out.stderr), "panic: oops\n");
    }

    #[test]
    fn unsupported_features_are_reported_not_miscompiled() {
        let out = run_source("list.ox", "fn main() {\n    var xs = [1, 2]\n    print(xs.len())\n}\n");
        assert_eq!(out.status.code(), Some(1));
        assert!(String::from_utf8_lossy(&out.stderr).contains("error[E0500]"));
    }

    #[test]
    fn runtime_internals_are_hidden_from_programs() {
        let out = run_source("internal.ox", "fn main() {\n    print(__load64(0))\n    __rt_exit(3)\n}\n");
        assert_eq!(out.status.code(), Some(1));
        assert!(String::from_utf8_lossy(&out.stderr).contains("error[E0100]"));
    }

    #[test]
    fn built_executables_are_standalone() {
        let dir = std::env::temp_dir().join(format!("onyx-native-build-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let source = dir.join("hello.ox");
        let exe = dir.join("hello");
        std::fs::write(&source, "fn main() {\n    print(\"standalone\")\n}\n").unwrap();
        let status = Command::new(ONYX).args(["build", "--target", "native"]).arg(&source).arg("-o").arg(&exe).status().unwrap();
        assert!(status.success());
        // No PATH, no environment: the program needs nothing but the kernel.
        let out = Command::new(&exe).env_clear().output().unwrap();
        assert_eq!(String::from_utf8_lossy(&out.stdout), "standalone\n");
        let _ = std::fs::remove_dir_all(&dir);
    }
}
