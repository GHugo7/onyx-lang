# The compiler in Onyx

The Onyx compiler was first written in Rust (`src/`). It now also exists
written in Onyx itself (`compiler/`): the whole `onyx` command, both
targets included, and it compiles its own source. Onyx needs nothing but
Onyx.

It was built stage by stage. Each stage was checked against the Rust
compiler on every Onyx file of the repository, so that a difference showed
up the day it appeared; `cargo test` keeps checking all of them.

| Stage | What | Status |
| --- | --- | --- |
| 1 | Lexer: source text to tokens (`compiler/lexer.ox`) | done |
| 2 | Parser: tokens to a syntax tree (`compiler/parser.ox`, `compiler/ast.ox`) | done |
| 3 | Modules: `import`, names across files (`compiler/modules.ox`) | done |
| 4 | Type checker (`compiler/checker.ox`) | done |
| 5a | Preparation for the code generator: `match` rewritten, constants computed, conversions, captured variables, `?` (`compiler/desugar.ox`, `optimize.ox`, `widen.ox`, `capture.ox`, `lower.ox`) | done |
| 5b | Native code generator, register planning, assembler, executable file (`compiler/gen.ox`, `plan.ox`, `asm.ox`, `elf.ox`) | done |
| 6 | The Onyx compiler compiles itself | done |
| 7 | The `onyx` command: `run`, `build`, `check`, `test`, `explain`, the JavaScript target, errors shown with their source (`compiler/main.ox`, `js.ox`, `errors.ox`) | done |

## Using it

The Rust compiler builds the first one:

```bash
onyx build --target native compiler/main.ox -o oxc
```

`oxc` is then the `onyx` command, complete: the same commands and options,
the same messages and exit codes, and the same files written, byte for
byte. Put it in a folder of your `PATH` under the name `onyx`, and the
Rust compiler is not needed any more:

```bash
./oxc run examples/hello.ox
```

```bash
./oxc build --target native examples/hello.ox -o hello
```

```bash
./oxc test examples
```

`cargo test` runs every command of the test suite with both (each program
of `tests/run` and `tests/native` on both targets, each program of
`tests/errors`, the tests of the examples...) and compares what they print
and what they write. Beyond the repository, the executables and the
JavaScript files of 2300 programs written by the fuzzer are the same.

And it compiles itself:

```bash
./oxc build --target native compiler/main.ox -o oxc2
```

`oxc2` is `oxc`, byte for byte, and so is what `oxc2` makes of the same
source: a fixed point. The 18600 lines of the compiler, plus the 4000 of
the native runtime, compile in a quarter of a second, into a 920 KB
executable. It carries the runtimes of both targets (`src/native/runtime.ox`
and `src/runtime.js`) and the explanations of the error codes
(`docs/errors.md`), read when it is compiled with `embed`.

## Looking at each stage

```bash
onyx run --target native compiler/main.ox tokens examples/hello.ox
```

```bash
onyx run --target native compiler/main.ox ast examples/hello.ox
```

print the tokens of a file, one per line, and its syntax tree, one node per
line with the children indented, in the same form as

```bash
onyx tokens examples/hello.ox
```

```bash
onyx ast examples/hello.ox
```

of the Rust compiler. `cargo test` compares the two on every file, and an
error in a file must be the same one, at the same place, with the same
message. The parser was also compared on several hundred damaged copies of
the repository's files (cut short, with bytes left out or added).

Built natively, the Onyx compiler parses the 4000 lines of the runtime in
17 ms; the Rust compiler takes 12 ms.

`onyx modules file` and `compiler/main.ox modules file` print the program
once all its files are linked into one (stage 3); `tests/modules` holds a
project made to exercise the awkward cases of imports.

`onyx types file` and `compiler/main.ox types file` print what the type
checker finds out (stage 4): the type of every expression, what each call
calls, which bodies of code may wait, the signatures; or every problem,
with its label and its help, word for word. Besides every file of the
repository, the two checkers were compared on several hundred copies of
them with one change each (a type replaced, a `?` removed, an argument
added...), which makes them report errors of all kinds.

Built natively, the Onyx checker checks the 6400 lines of the Onyx compiler
in 62 ms; the Rust one takes 28 ms.

`onyx lowered file` and `compiler/main.ox lowered file` print the program as
the native code generator receives it (stage 5a): with the runtime added,
checked, then rewritten by the passes that come before the code generator.

- `desugar`: every `match` becomes `if` / `else` tests on `__tag` (which
  variant a value is) and `__field` (what it carries).
- `optimize`: constant expressions are computed (`2 * 60` is `120`), short
  `const` values are copied where they are used, branches that can never run
  are removed.
- `widen`: an `int` used where a `float` is expected is converted
  (`sqrt(n)` is `sqrt(float(n))`).
- `capture`: what each lambda uses from the functions around it; a variable
  that a lambda changes moves into a box shared by both, and `fork { ... }`
  becomes a lambda handed to the runtime.
- `lower`: every `?` is moved to the root of a statement, what is computed
  before it going into temporary variables, so that a failure leaves nothing
  half-built.

The dump shows every expression with its id, every float with its exact
bits, the type of every expression, and what each lambda captures: both
compilers must make the same new nodes, with the same ids, in the same
order. Besides every file of the repository, they were compared on 2300
programs made by the fuzzer (`ONYX_FUZZ_SAVE=dir` writes them out), and
`tests/native/rewrites.ox` goes through every rewrite on purpose.

On the Onyx compiler itself (9700 lines, plus the 4000 of the runtime),
the whole stage, printing included, takes 140 ms built natively; the Rust
compiler takes 120 ms.

## How the two differ

- The Onyx lexer accepts any character outside ASCII in a name; the Rust
  one only accepts letters and digits.
- The Rust compiler asks the system for the real path of a file to tell
  whether two imports name the same one; the Onyx compiler tidies the path
  up itself (`a/./b/../c.ox` is `a/c.ox`). They only disagree when symbolic
  links are involved.
- Built for the JavaScript target, the Onyx compiler cannot hold integers
  beyond 2^53 exactly (JavaScript numbers have 53 bits): the 64-bit
  constants of the runtime and the bits of floats come out rounded in
  `lowered`. The native build is the one that counts.

## The runtimes

A native program needs the runtime written in Onyx (`src/native/runtime.ox`),
and a JavaScript program the one written in JavaScript (`src/runtime.js`).
The Rust compiler carries both in its executable; the Onyx compiler does the
same with `embed`, a function of the language that the compiler replaces by
the text of a file (see the [standard library](stdlib.md)). The two
compilers also share the explanations of the error codes,
[docs/errors.md](errors.md).

## What the language gained for this

Writing a compiler needs a few things that small programs can do without,
and they were added first: enums and `match` (a syntax tree is made of
them), operations on bits, `ord` / `chr`, byte lists that can be read from
and written to files (an executable is bytes), and `embed`. Then, for the
code generator: numbers written in hexadecimal (`0x8B`, an opcode, reads
better than `139`) and `set_executable`, so that what `oxc` writes can be
run. Then, for the command itself: `eprint` for the error output,
`run_program` to start node or the program just built, `list_dir`,
`is_dir`, `make_dir`, `remove_file` and `remove_dir` for the folders of
`onyx test` and `build`, and `stderr_is_terminal` to know whether errors can
be shown in color.
