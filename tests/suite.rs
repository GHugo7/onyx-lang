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
    /// JavaScript target prints for the same source. They must also have
    /// released every object by the time they exit.
    #[test]
    fn native_and_javascript_agree() {
        for file in programs("tests/native") {
            let expected = std::fs::read_to_string(file.with_extension("out")).unwrap();
            let native =
                Command::new(ONYX).args(["run", "--target", "native", "--leak-check"]).arg(&file).output().unwrap();
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

    /// Divisions, remainders and multiplications by constants are compiled
    /// into shifts and multiplications. Over the whole 64-bit range, which
    /// JavaScript cannot check, they must agree with the same operations done
    /// with the processor's division instruction (a divisor in a variable).
    #[test]
    fn arithmetic_with_constants_is_exact_on_64_bits() {
        let divisors: [i64; 30] = [
            1, -1, 2, -2, 3, -3, 5, 7, -7, 8, 10, -10, 16, 60, 100, 127, 255, 256, 641, 1000, 4096, 65535, 65536, 99999,
            1000003, 1048576, 123456789, 2147483647, -2147483647, -2147483648,
        ];
        let inputs = "[0, 1, -1, 99, -100, 4294967295, -4294967296, 9007199254740993, -9007199254740993, \
            1152921504606846975, -1152921504606846976, 4611686018427387904, -4611686018427387905, \
            9223372036854775806, 9223372036854775807, -9223372036854775807, -9223372036854775807 - 1, \
            6148914691236517205, -6148914691236517206, 1234567890123456789, -987654321098765432]";
        let mut src = format!("fn main() {{\n    var inputs = {inputs}\n    var a: [int] = []\n    for x in inputs {{\n");
        for d in divisors {
            src.push_str(&format!("        a.push(x / {d})\n        a.push(x % {d})\n"));
        }
        for m in [0i64, 1, -1, 2, 3, 8, 10, -16, 1000, 65536] {
            src.push_str(&format!("        a.push((x / 65536) * {m})\n"));
        }
        src.push_str("    }\n    var divisors = [");
        src.push_str(&divisors.map(|d| if d == i64::from(i32::MIN) { "-2147483647 - 1".to_string() } else { d.to_string() }).join(", "));
        src.push_str("]\n    var factors = [0, 1, -1, 2, 3, 8, 10, -16, 1000, 65536]\n");
        src.push_str("    var b: [int] = []\n    for x in inputs {\n        for d in divisors {\n");
        src.push_str("            b.push(x / d)\n            b.push(x % d)\n        }\n");
        src.push_str("        for m in factors {\n            b.push((x / 65536) * m)\n        }\n    }\n");
        src.push_str("    print(a.len(), a == b)\n    print(inputs[14] / 10, inputs[16] / 7, inputs[16] % 1000, inputs[16] / -1, inputs[16] % -1)\n}\n");
        let out = run_source("exact.ox", &src);
        assert_eq!(
            String::from_utf8_lossy(&out.stdout),
            "1470 true\n922337203685477580 -1317624576693539401 -808 -9223372036854775808 0\n",
            "{}",
            String::from_utf8_lossy(&out.stderr)
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
        let out = run_source("fork.ox", "fn main() {\n    fork {\n        print(1)\n    }\n}\n");
        assert_eq!(out.status.code(), Some(1));
        assert!(String::from_utf8_lossy(&out.stderr).contains("error[E0500]"));
    }

    #[test]
    fn out_of_bounds_access_panics() {
        let out = run_source("bounds.ox", "fn main() {\n    var xs = [1, 2, 3]\n    print(xs[3])\n}\n");
        assert_eq!(out.status.code(), Some(2));
        assert_eq!(String::from_utf8_lossy(&out.stderr), "panic: index out of bounds: index 3, length 3\n");
    }

    /// Reference counting cannot free objects that point to each other; the
    /// leak check must notice (and so proves that it really counts).
    #[test]
    fn leak_check_reports_cycles() {
        let dir = std::env::temp_dir().join(format!("onyx-native-leak-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("cycle.ox");
        let src = "struct Node {\n    friends: [Node]\n}\n\nfn main() {\n    var a = Node{friends: []}\n    var b = Node{friends: []}\n    a.friends.push(b)\n    b.friends.push(a)\n}\n";
        std::fs::write(&file, src).unwrap();
        let out = Command::new(ONYX).args(["run", "--target", "native", "--leak-check"]).arg(&file).output().unwrap();
        assert_eq!(out.status.code(), Some(3));
        assert_eq!(String::from_utf8_lossy(&out.stderr), "leak check: 4 object(s) were never released\n");
        let _ = std::fs::remove_dir_all(&dir);
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
