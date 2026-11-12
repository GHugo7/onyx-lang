# 5. Error handling

Onyx has no exceptions and no `null`. A function that can fail says so with a
`!` after its return type, and reports the failure with `fail`.

```onyx
fn divide(a: int, b: int) -> int! {
    if b == 0 {
        fail "cannot divide {a} by zero"
    }
    return a / b
}

fn main() {
    print(divide(10, 2) or 0)
}
```

A function that returns nothing but can fail is written `-> void!`.

## You must choose

Calling `divide(10, 2)` on its own does not compile:

```text
error[E0200]: `divide()` can fail
  = help: handle it with `?`, `or`, or `catch`
```

There are three ways to answer.

### `or`: use a default

```onyx
fn main() {
    var port = parse_int("80a") or 8080
    var config = read_file("config.txt") or "default config"
    print(port, config)
}
```

`or` applies to the whole expression on its left, so use parentheses inside a
larger one: `1 + (parse_int(s) or 0)`.

### `catch`: handle it here

The block receives the error. It must either leave (`return`, `fail`, `break`,
`continue`) or end with a replacement value.

```onyx
fn main() {
    var text = read_file("notes.txt") catch err {
        print("no notes: {err}")
        return
    }
    print(text)

    var count = parse_int(text) catch err {
        print("not a number, using 1")
        1
    }
    print(count)
}
```

`err` has the type `error`; `err.message` is its text, and printing it shows
the message.

### `?`: pass it to my caller

Inside a function that can itself fail, `?` returns the error immediately.

```onyx
struct Config {
    host: string
    port: int
}

fn load(path: string) -> Config! {
    var lines = read_file(path)?.split("\n")
    if lines.len() < 2 {
        fail "{path}: expected two lines"
    }
    return Config{host: lines[0], port: parse_int(lines[1])?}
}

fn main() -> void! {
    var config = load("server.conf")?
    print(config)
}
```

`main` may be declared `-> void!`. An error that reaches the top prints
`error: <message>` and the program exits with code 1.

## Errors and panics

A *failure* (`fail`) is an expected situation the caller should deal with: a
missing file, bad input. A *panic* is a bug: indexing past the end of a list,
dividing an `int` by zero, a missing map key with `m[key]`. Panics stop the
program and cannot be caught. Call `panic("message")` to raise one yourself.

Next: [Concurrency](06-concurrency.md)
