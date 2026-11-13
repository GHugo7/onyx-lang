// Lambdas, closures and functions as values.

struct Button {
    label: string
    on_click: fn(string) -> string
    presses: int

    fn press(self) -> string {
        self.presses += 1
        return self.on_click(self.label)
    }

    fn renamer(self) -> fn(string) {
        return fn(name: string) {
            self.label = name
        }
    }
}

struct Person {
    name: string
    age: int
}

var g_log: [string] = []
var g_twice = fn(n: int) -> int {
    return n * 2
}

fn double(n: int) -> int {
    return n * 2
}

fn apply(f: fn(int) -> int, n: int) -> int {
    return f(n)
}

fn compose(f: fn(int) -> int, g: fn(int) -> int) -> fn(int) -> int {
    return fn(n: int) -> int {
        return g(f(n))
    }
}

fn adder(k: int) -> fn(int) -> int {
    return fn(n: int) -> int {
        return n + k
    }
}

fn counter() -> fn() -> int {
    var n = 0
    return fn() -> int {
        n += 1
        return n
    }
}

// Two lambdas sharing one variable, which the function also changes.
fn account(start: int) -> [fn(int) -> int] {
    var balance = start
    balance += 1
    var deposit = fn(amount: int) -> int {
        balance += amount
        return balance
    }
    var withdraw = fn(amount: int) -> int {
        balance -= amount
        return balance
    }
    balance -= 1
    return [deposit, withdraw]
}

fn accumulate(prefix: string) -> fn(string) -> string {
    var text = prefix
    return fn(piece: string) -> string {
        text += piece
        return text
    }
}

// A parameter that is captured and assigned.
fn countdown(from: int) -> fn() -> int {
    return fn() -> int {
        from -= 1
        return from
    }
}

fn checked(limit: int) -> fn(int) -> int! {
    return fn(n: int) -> int! {
        if n > limit {
            fail "{n} is over {limit}"
        }
        return n * 10
    }
}

fn run_checked(f: fn(int) -> int!, n: int) -> int! {
    var value = f(n)?
    return value + f(1)?
}

fn logger(tag: string) -> fn(string) {
    return fn(message: string) {
        g_log.push("[{tag}] {message}")
    }
}

fn nested(a: int) -> fn(int) -> fn(int) -> int {
    return fn(b: int) -> fn(int) -> int {
        var total = a + b
        return fn(c: int) -> int {
            total += c
            return total + a
        }
    }
}

fn main() {
    // plain function values
    var f = double
    print(f(4), apply(double, 5), apply(f, 6), g_twice(7), apply(g_twice, 8), f)
    var square = fn(n: int) -> int {
        return n * n
    }
    print(square(9), apply(square, 3), compose(double, square)(3), compose(square, double)(3))

    // captured values
    var add5 = adder(5)
    var add10 = adder(10)
    print(add5(1), add10(1), adder(100)(1), compose(add5, add10)(0))
    var greeting = "hello"
    var greet = fn(name: string) -> string {
        return "{greeting}, {name}!"
    }
    print(greet("Ada"), greet("Grace"))

    // captured variables that change
    var next = counter()
    var other = counter()
    print(next(), next(), next(), other(), next())
    var ops = account(100)
    print(ops[0](50), ops[1](30), ops[0](1), ops[1](200))
    var say = accumulate(">")
    print(say("a"), say("b"), say("c"))
    var tick = countdown(3)
    print(tick(), tick(), tick())
    var hits = 0
    var bump = fn() {
        hits += 1
    }
    bump()
    bump()
    hits += 10
    bump()
    print(hits)

    // one closure per turn of a loop
    var makers: [fn() -> int] = []
    for i in 0..4 {
        var twice = i * 2
        makers.push(fn() -> int {
            return i * 100 + twice
        })
    }
    var sum = 0
    for make in makers {
        sum += make()
    }
    print(sum, makers.len(), makers[3](), makers)
    var totals: [fn(int) -> int] = []
    var k = 0
    while k < 3 {
        var running = k * 10
        totals.push(fn(n: int) -> int {
            running += n
            return running
        })
        k += 1
    }
    print(totals[0](1), totals[0](1), totals[1](1), totals[2](5), totals[2](5))

    // closures in structs and maps
    var shout = Button{label: "ok", on_click: fn(text: string) -> string {
        return text.upper() + "!"
    }, presses: 0}
    print(shout.press(), shout.press(), shout.presses)
    var rename = shout.renamer()
    rename("cancel")
    print(shout.press(), shout.label, shout.on_click("direct"))
    var table: map<string, fn(int) -> int> = {"double": double, "square": square}
    table["add5"] = add5
    for name in table.keys().sort() {
        print(name, table[name](6))
    }

    // lambdas that can fail
    var limited = checked(5)
    print(limited(3) or -1, limited(9) or -1, run_checked(limited, 2) or -1, run_checked(limited, 7) or -1)
    limited(99) catch err {
        print("caught:", err)
    }

    // lambdas with side effects
    var info = logger("info")
    var warn = logger("warn")
    info("starting")
    warn("careful")
    info("done")
    print(g_log)

    // nesting
    var step = nested(1)(2)
    print(step(10), step(10), nested(5)(5)(5))

    // map, filter, sort_by
    var numbers = [5, 3, 8, 1, 9, 2]
    var threshold = 4
    print(numbers.map(double), numbers.filter(fn(n: int) -> bool {
        return n > threshold
    }), numbers.map(fn(n: int) -> string {
        return "<{n}>"
    }))
    print(numbers.sort_by(fn(n: int) -> int {
        return -n
    }), numbers.map(fn(n: int) -> float {
        return n / 2.0
    }), numbers.filter(fn(n: int) -> bool {
        return false
    }), numbers)
    var people = [Person{name: "Cleo", age: 31}, Person{name: "Abe", age: 44}, Person{name: "Bea", age: 31}, Person{name: "Dan", age: 19}]
    print(people.sort_by(fn(p: Person) -> int {
        return p.age
    }).map(fn(p: Person) -> string {
        return p.name
    }), people.sort_by(fn(p: Person) -> string {
        return p.name
    }).map(fn(p: Person) -> int {
        return p.age
    }), people.sort_by(fn(p: Person) -> float {
        return 1.0 / p.age
    }).map(fn(p: Person) -> string {
        return p.name
    }))
    var adults = people.filter(fn(p: Person) -> bool {
        return p.age >= 30
    })
    var names: [string] = []
    var total_age = 0
    adults.map(fn(p: Person) -> int {
        names.push(p.name)
        total_age += p.age
        return 0
    })
    print(adults.len(), names, total_age, ["b", "a", "c"].sort_by(fn(s: string) -> string {
        return s
    }), [7].map(double))
    var empty: [string] = []
    print(empty.map(fn(s: string) -> int {
        return s.len()
    }), empty.sort_by(fn(s: string) -> int {
        return 0
    }), ["x", "yy"].filter(fn(s: string) -> bool {
        return s.len() > 1
    }))
}
