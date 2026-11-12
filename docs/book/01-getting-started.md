# 1. Getting started

## Install

Onyx needs [Rust](https://rustup.rs) to build the compiler and
[Node.js](https://nodejs.org) 18+ to run programs.

```bash
cargo install --git https://github.com/GHugo7/onyx-lang
```

```bash
onyx version
```

## Your first program

Create a file named `hello.ox`:

```onyx
fn main() {
    print("Hello, Onyx!")
}
```

Run it:

```bash
onyx run hello.ox
```

Every program starts in `fn main()`. Only declarations (`import`, `fn`,
`struct`, `interface`, `var`, `const`, `check`) may appear at the top level of a file.

## The commands

| Command | What it does |
| --- | --- |
| `onyx run file.ox [args]` | Compiles and runs the program |
| `onyx check file.ox` | Reports errors without running |
| `onyx test file.ox` | Runs the file's `check` blocks |
| `onyx build file.ox` | Writes `build/file.js`, which runs with `node` or in a browser |
| `onyx explain E0200` | Explains an error code in detail |

## How it works

Onyx is a compiled language. `onyx run` type-checks your program, translates it
to JavaScript in memory and hands it to Node.js. Your `.ox` file is never
modified, and nothing else is written to disk unless you ask for it with
`onyx build`.

## Syntax in one minute

```onyx
// A comment. /* Block comments work too. */

fn main() {
    var total = 0                 // statements end at the end of the line
    for i in 0..5 {               // braces are required, parentheses are not
        if i % 2 == 0 {
            total += i
        }
    }
    print("total is {total}")     // {expressions} inside strings
}
```

Next: [Variables and types](02-variables-and-types.md)
