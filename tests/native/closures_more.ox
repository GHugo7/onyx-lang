// Closures in less common places.

var g_base = 10
var g_scale = fn(n: int) -> int {
    return n * g_base
}
var g_fact = fn(n: int) -> int {
    return n
}
var g_handlers: [fn(float) -> float] = []

fn half(n: int) -> int! {
    if n % 2 != 0 {
        fail "{n} is odd"
    }
    return n / 2
}

fn halver() -> fn(int) -> int! {
    return fn(n: int) -> int! {
        var once = half(n)?
        return half(once)? + (half(once * 2) or 0)
    }
}

fn each(xs: [int], f: fn(int)) {
    for x in xs {
        f(x)
    }
}

fn memo() -> fn(int) -> int {
    var cache: map<int, int> = {}
    var calls = 0
    return fn(n: int) -> int {
        if cache.has(n) {
            return cache[n]
        }
        calls += 1
        cache[n] = n * n + calls
        return cache[n]
    }
}

fn pipeline(steps: [fn(float) -> float], x: float) -> float {
    var value = x
    for step in steps {
        value = step(value)
    }
    return value
}

fn main() {
    // top-level lambdas see top-level variables as they are now
    print(g_scale(4))
    g_base = 3
    print(g_scale(4))
    // a top-level function that calls itself through its variable
    g_fact = fn(n: int) -> int {
        if n <= 1 {
            return 1
        }
        return n * g_fact(n - 1)
    }
    print(g_fact(10))

    // `?`, `or` and `catch` inside a lambda
    var quarter = halver()
    print(quarter(8) or -1, quarter(6) or -1, quarter(3) or -1)
    var safe = fn(text: string) -> int {
        var value = parse_int(text) catch err {
            return -err.message.len()
        }
        return value
    }
    print(safe("12"), safe("x"))

    // captured: a loop variable, a list, a float, an error
    var seen: [int] = []
    var total = 0.5
    each([3, 1, 2], fn(x: int) {
        seen.push(x * 2)
        total += x
    })
    print(seen, total)
    var words = ["a", "bb", "ccc"]
    var lengths: [fn() -> int] = []
    for w in words {
        lengths.push(fn() -> int {
            return w.len()
        })
    }
    print(lengths[0]() + lengths[1]() * 10 + lengths[2]() * 100)
    half(7) catch err {
        var report = fn() -> string {
            return "failed: {err}"
        }
        print(report())
    }

    // state kept between calls
    var square = memo()
    print(square(4), square(4), square(5), square(4))

    // floats through function values
    g_handlers.push(fn(x: float) -> float {
        return x * 2
    })
    var offset = 1
    g_handlers.push(fn(x: float) -> float {
        return x + offset / 4.0
    })
    g_handlers.push(sqrt_of)
    print(pipeline(g_handlers, 8), g_handlers.len(), g_handlers.map(fn(h: fn(float) -> float) -> float {
        return h(1)
    }))

    // a lambda called right away, and one that returns another
    print(fn(n: int) -> int {
        return n + 1
    }(41))
    var make = fn(tag: string) -> fn() -> string {
        var count = 0
        return fn() -> string {
            count += 1
            return "{tag}{count}"
        }
    }
    var a = make("a")
    var b = make("b")
    print(a(), a(), b(), a())

    // a variable changed after the lambda was made
    var mode = "before"
    var show = fn() -> string {
        return mode
    }
    mode = "after"
    print(show())
    var parts: [string] = []
    var add = fn(s: string) {
        parts.push(s)
    }
    add("x")
    parts = ["reset"]
    add("y")
    print(parts)
}

fn sqrt_of(x: float) -> float {
    return sqrt(x)
}
