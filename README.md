# Onyx

Onyx is a small, statically typed programming language. It borrows the
structure of Java, the simplicity of Go and the lightness of JavaScript, and
adds two ideas of its own:

- **Errors you cannot forget.** A function that can fail says so in its type
  (`-> string!`), and every call must choose what happens on failure: `?`,
  `or`, or `catch`. There is no `null` and there are no exceptions.
- **Concurrency in one word.** `fork { ... }` starts a task; tasks talk through
  typed channels.

```onyx
struct Player {
    name: string
    score: int
}

fn load_scores(path: string) -> [Player]! {
    var players: [Player] = []
    for line in read_file(path)?.split("\n") {
        var parts = line.split(",")
        if parts.len() != 2 {
            fail "bad line: {line}"
        }
        players.push(Player{name: parts[0], score: parse_int(parts[1])?})
    }
    return players
}

fn main() {
    var players = load_scores("scores.csv") catch err {
        print("could not load scores: {err}")
        return
    }
    for p in players {
        print("{p.name}: {p.score}")
    }
}
```

The compiler is written in Rust with no dependencies. Source files use the
`.ox` extension.

> **Status: v0.1, early.** The language core works and is tested. Programs
> compile to JavaScript, and an experimental [native target](docs/native.md)
> writes Linux executables directly, with no other tool involved. See the
> [roadmap](docs/roadmap.md).

## Install

You need [Rust](https://rustup.rs) to build the compiler and
[Node.js](https://nodejs.org) 18 or newer to run programs.

```bash
cargo install --git https://github.com/GHugo7/onyx-lang
```

## Use

```bash
onyx run hello.ox          # compile and run
onyx check hello.ox        # type-check only
onyx test hello.ox         # run the file's `check` blocks
onyx build hello.ox        # write build/hello.js
onyx build --target native hello.ox   # write build/hello, a Linux executable
onyx explain E0200         # explain an error code
```

`hello.ox`:

```onyx
fn main() {
    var name = "world"
    print("Hello, {name}!")
}
```

## A taste of the language

### Errors

```onyx
fn half(n: int) -> int! {
    if n % 2 != 0 {
        fail "{n} is odd"
    }
    return n / 2
}

fn quarter(n: int) -> int! {
    return half(half(n)?)?          // `?` passes the error to the caller
}

fn main() {
    print(quarter(12) or 0)         // `or` gives a default value

    var q = quarter(6) catch err {  // `catch` handles it here
        print("failed: {err}")
        return
    }
    print(q)
}
```

Forgetting to handle a call is a compile-time error:

```text
error[E0200]: `half()` can fail
 --> main.ox:9:13
  |
9 |     var h = half(n)
  |             ^^^^^^^ this call may return an error
  |
  = help: handle it with `?`, `or`, or `catch`
```

### Concurrency

```onyx
fn fetch_length(url: string, out: chan<string>) {
    var body = fetch(url) or ""
    out <- "{url}: {body.len()} bytes"
}

fn main() {
    var urls = ["https://example.com", "https://example.org"]
    var results = chan<string>()
    for url in urls {
        fork { fetch_length(url, results) }   // both downloads run at once
    }
    for url in urls {
        print(<-results)
    }
}
```

### Structs and interfaces

```onyx
interface Shape {
    fn area(self) -> float
}

struct Circle {
    radius: float

    fn area(self) -> float {
        return 3.14159 * self.radius * self.radius
    }
}

struct Square {
    side: float

    fn area(self) -> float {
        return self.side * self.side
    }
}

fn main() {
    // A struct implements an interface simply by having its methods.
    var shapes: [Shape] = [Circle{radius: 1.0}, Square{side: 2.0}]
    for s in shapes {
        print(s.area())
    }
}
```

### Modules

```onyx
import "lib/geometry" as geo

fn main() {
    var p = geo.Point{x: 3, y: 4}
    print(geo.distance(p, geo.origin()))
}
```

### Built-in tests

```onyx
fn add(a: int, b: int) -> int {
    return a + b
}

fn main() {
    print(add(2, 2))
}

check "add works" {
    expect(add(2, 2) == 4)
}
```

## Learn more

- [The Onyx Book](docs/book/README.md): a guided tour, chapter by chapter
- [Standard library reference](docs/stdlib.md)
- [The native target](docs/native.md)
- [Examples](examples)
- [Roadmap](docs/roadmap.md)

## Working on the compiler

```bash
cargo build
cargo test        # runs every program in tests/ and every example in the docs
```

The pipeline is `lexer.rs` → `parser.rs` → `modules.rs` (imports) →
`checker.rs` → `codegen_js.rs`,
with the JavaScript runtime in `src/runtime.js`. The native backend lives in
`src/native` and its runtime is written in Onyx (`src/native/runtime.ox`). To add a test, drop a `.ox`
file and its expected `.out` in `tests/run`, or a program that must be rejected
in `tests/errors` with `// error: E....` on its first line.

## License

MIT
