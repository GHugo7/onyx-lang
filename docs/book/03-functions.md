# 3. Functions

Parameters and return values are always typed.

```onyx
fn area(width: float, height: float) -> float {
    return width * height
}

fn greet(name: string) {        // no arrow: returns nothing
    print("hello {name}")
}

fn main() {
    greet("Onyx")
    print(area(2, 3.5))
}
```

A function that declares a return type must return on every path; the compiler
checks it.

## Functions are values

A function can be stored, passed around and returned. Its type is written
`fn(parameters) -> result`.

```onyx
fn twice(f: fn(int) -> int, x: int) -> int {
    return f(f(x))
}

fn add_one(x: int) -> int {
    return x + 1
}

fn main() {
    print(twice(add_one, 5))                                 // 7
    print(twice(fn(x: int) -> int { return x * x }, 3))      // 81
}
```

## Lambdas and closures

`fn` without a name creates a function in place. It can read and change the
variables around it.

```onyx
fn make_counter() -> fn() -> int {
    let count = 0
    return fn() -> int {
        count += 1
        return count
    }
}

fn main() {
    let next = make_counter()
    next()
    next()
    print(next())    // 3

    let words = ["kiwi", "fig", "banana"]
    print(words.filter(fn(w: string) -> bool { return w.len() > 3 }))
    print(words.map(fn(w: string) -> int { return w.len() }))
    print(words.sort_by(fn(w: string) -> int { return w.len() }))
}
```

Next: [Structs and interfaces](04-structs-and-interfaces.md)
