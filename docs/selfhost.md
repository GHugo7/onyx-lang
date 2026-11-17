# The compiler in Onyx

The Onyx compiler is written in Rust (`src/`). The goal is a compiler
written in Onyx itself (`compiler/`), able to compile its own source: from
then on, Onyx needs nothing but Onyx.

It is built stage by stage. Each stage is checked against the Rust compiler
on every Onyx file of the repository, so that a difference shows up the day
it appears.

| Stage | What | Status |
| --- | --- | --- |
| 1 | Lexer: source text to tokens (`compiler/lexer.ox`) | done |
| 2 | Parser: tokens to a syntax tree (`compiler/parser.ox`, `compiler/ast.ox`) | done |
| 3 | Modules: `import`, names across files (`compiler/modules.ox`) | done |
| 4 | Type checker (`compiler/checker.ox`) | done |
| 5 | Native code generator and ELF writer | next |
| 6 | The Onyx compiler compiles itself | |

## Trying it

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

## How the two differ

- The Onyx lexer accepts any character outside ASCII in a name; the Rust
  one only accepts letters and digits.
- The Rust compiler asks the system for the real path of a file to tell
  whether two imports name the same one; the Onyx compiler tidies the path
  up itself (`a/./b/../c.ox` is `a/c.ox`). They only disagree when symbolic
  links are involved.

## What the language gained for this

Writing a compiler needs a few things that small programs can do without,
and they were added first: enums and `match` (a syntax tree is made of
them), operations on bits, `ord` / `chr`, and byte lists that can be read
from and written to files (an executable is bytes).
