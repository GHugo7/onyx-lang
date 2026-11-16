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
| 2 | Parser: tokens to a syntax tree | next |
| 3 | Modules: `import`, names across files | |
| 4 | Type checker | |
| 5 | Native code generator and ELF writer | |
| 6 | The Onyx compiler compiles itself | |

## Trying it

```bash
onyx run --target native compiler/main.ox tokens examples/hello.ox
```

prints the tokens of a file, one per line, in the same form as

```bash
onyx tokens examples/hello.ox
```

of the Rust compiler. `cargo test` compares the two on every file.

## How the two differ

- The Onyx lexer accepts any character outside ASCII in a name; the Rust
  one only accepts letters and digits.

## What the language gained for this

Writing a compiler needs a few things that small programs can do without,
and they were added first: enums and `match` (a syntax tree is made of
them), operations on bits, `ord` / `chr`, and byte lists that can be read
from and written to files (an executable is bytes).
