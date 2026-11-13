# 2. Variables and types

## var and const

`var` declares a variable, `const` a value that never changes.

```onyx
const MAX_PLAYERS = 4

fn main() {
    var score = 10          // the type is inferred: int
    var name: string = "Al" // or written explicitly
    score = score + 5
    print("{name} has {score} of {MAX_PLAYERS}")
}
```

Variables declared outside of any function are visible everywhere. They get
their values one after the other, from top to bottom, before `main` starts;
the compiler refuses a program in which one of them would be used before its
turn (`onyx explain E0118`).

Onyx is statically typed: a variable keeps the type it was created with.
Assigning a string to `score` is a compile-time error. Every variable must be
given a value when it is declared; there is no `null`.

## Basic types

| Type | Examples | Notes |
| --- | --- | --- |
| `int` | `42`, `-7`, `1_000_000` | whole numbers |
| `float` | `3.14`, `2.0`, `1.5e-7` | decimal numbers |
| `bool` | `true`, `false` | |
| `string` | `"hello"` | text, double quotes only |

An `int` is accepted wherever a `float` is expected. Every other conversion is
explicit:

```onyx
fn main() {
    var n = 7
    var half: float = n            // int -> float is automatic
    print(half / 2)                // 3.5
    print(n / 2)                   // 3: dividing two ints gives an int
    print(int(3.9), round(3.9))    // 3 4
    print(float(n) / 2)            // 3.5
    print(str(n) + "!")            // "7!"
    print(parse_int("12") or 0)    // text -> int can fail, see chapter 5
}
```

## Operators

- Arithmetic: `+ - * / %`
- Comparison: `== != < <= > >=`
- Logic: `&& || !`
- Assignment: `= += -= *= /=`

`+` also joins two strings. `==` compares by value, including lists, maps and
structs.

## Strings

Put any expression between braces to insert it in a string. Write `\{` for a
literal brace.

```onyx
fn main() {
    var name = "Sam"
    var items = [1, 2, 3]
    print("{name} has {items.len()} items, twice that is {items.len() * 2}")
    print("JSON looks like \{\"a\": 1\}")
    print(name.upper(), name.len(), name.contains("a"))
}
```

## Lists

A list holds values of one type and can grow.

```onyx
fn main() {
    var names = ["Ada", "Linus"]
    names.push("Grace")
    names[0] = "Alan"
    print(names, names.len(), names[2])

    var scores: [int] = []       // an empty list needs a type
    scores.push(3)

    for name in names {
        print(name)
    }
}
```

Reading past the end of a list stops the program with a panic.

## Maps

A map associates keys (`int`, `string` or `bool`) with values.

```onyx
fn main() {
    var ages = {"Ada": 36, "Linus": 54}
    ages["Grace"] = 85
    print(ages["Ada"], ages.has("Bob"), ages.len())

    // `m[key]` panics when the key is missing. `get` lets you decide instead:
    print(ages.get("Bob") or 0)

    for name in ages {
        print("{name} is {ages[name]}")
    }

    var empty: map<string, int> = {}
    print(empty.len())
}
```

## Control flow

```onyx
fn main() {
    var n = 7
    if n > 5 {
        print("big")
    } else if n > 2 {
        print("medium")
    } else {
        print("small")
    }

    var i = 0
    while i < 3 {
        i += 1
    }

    for i in 0..3 {          // 0, 1, 2
        if i == 1 { continue }
        print(i)
    }
}
```

`for ... in` works on ranges (`a..b`, end excluded), lists, strings
(character by character), maps (their keys) and channels.

Next: [Functions](03-functions.md)
