// Goes through every rewrite the compiler makes before generating machine
// code: `match` (src/desugar.rs), constants (src/optimize.rs), int to float
// conversions, captured variables and `?` in the middle of expressions
// (src/native/widen.rs, capture.rs, lower.rs). The compiler written in Onyx
// must make exactly the same ones (`onyx lowered`).

enum Shape {
    Circle(float)
    Rect(float, float)
    Dot
    Empty
}

struct Point {
    x: float
    y: float
    count: int
}

struct Bag {
    items: [int]
    label: string

    fn add(self, n: int) -> int {
        self.items.push(n)
        return self.items.len()
    }

    // `self` is captured, and copied: it never changes.
    fn adder(self) -> fn(int) {
        return fn(n: int) {
            self.items.push(n * 100)
        }
    }
}

const LIMIT = 10
const HALF: float = 1
const GREETING = "hello"
const LONG = "this text is longer than sixty-four bytes, so it stays a variable of its own"
const SHOUT = GREETING + "!"

// A top-level variable that holds a lambda, whose body is lowered too.
var twice = fn(n: int) -> int! {
    return risky(n)? + risky(n)?
}

fn risky(n: int) -> int! {
    if n > LIMIT {
        fail "too big: {n}"
    }
    return n
}

fn positive(n: int) -> bool! {
    if n < 0 {
        fail "negative"
    }
    return n > 0
}

fn area(s: Shape) -> float {
    match s {
        Circle(r) {
            return 3.0 * r * r
        }
        Rect(w, _) {
            match s {
                Rect(_, h) {
                    return w * h
                }
                else {
                    return 0
                }
            }
        }
        Dot, Empty {
            return 0
        }
    }
}

fn name_of(n: int) -> string {
    match n {
        1, 2 {
            return "small"
        }
        3 {
            return "three"
        }
        else {
            return "big"
        }
    }
}

// A parameter that a lambda changes moves into a box.
fn counter(start: int) -> fn() -> int {
    return fn() -> int {
        start += 1
        return start
    }
}

fn lowered(n: int) -> int! {
    // `?` in the middle of expressions.
    var total = risky(1)? + risky(n)? * 2
    var xs = [risky(1)?, 2, risky(3)?]
    var m = {"a": risky(1)?, "b": risky(2)?}
    var p = Point{y: float(risky(2)?), count: risky(1)?, x: 1.5}
    var shape = Shape.Rect(float(risky(2)?), 3)
    print(xs, risky(1)?, p.count)
    print("{xs} and {risky(2)?} and {m}")
    // `&&` and `||` that only sometimes run their right side.
    var both = n > 0 && positive(n)?
    var either = n > 5 || positive(n - 1)?
    // `or` whose default may fail too.
    var safe = risky(n * 100) or risky(n)?
    // Assignments to fields and elements.
    p.count = risky(4)?
    xs[risky(0)?] += risky(5)?
    p.x += 2
    p.y *= risky(2)?
    xs[1] -= 1
    var bag = Bag{items: [], label: "bag"}
    var size = bag.add(risky(7)?) + bag.add(1)
    bag.adder()(3)
    // A loop whose condition can fail.
    var i = 0
    while risky(i)? < 3 {
        i += 1
    }
    if i > 100 {
        print("never")
    } else if positive(i)? && i > 1 {
        print("positive", i)
    }
    total += twice(2)?
    print(total, both, either, safe, p.x, p.y, xs, size, bag.items, i, area(shape))
    return total
}

fn main() {
    // Constants are copied where they are used, and computed.
    var seconds = 2 * 60 + LIMIT
    var ratio = HALF / 4
    var big = 9007199254740991 + 1
    var neg = -(5)
    var z = -0.0
    var cmp = "abc" < "abd"
    var accent = "é" < "z"
    var joined = SHOUT + " " + LONG
    print(seconds, ratio, big, neg, z == 0.0, cmp, accent, joined.len())
    print("{1 + 1} items, {true} and {LIMIT * 2}: {"nested {LIMIT}"}")
    if true {
        print("always")
    }
    if false {
        print("never")
    } else {
        print("else")
    }
    while false {
        print("never")
    }
    var flag = seconds > 0
    print(flag && true, false || flag, true && flag)
    // Widening ints to floats.
    var f: float = 3
    var g = seconds * 1.5
    var h = sqrt(16)
    f += seconds
    print(f, g, h)
    // Enums.
    print(area(Shape.Circle(1)), area(Shape.Rect(2, 3.5)), area(Shape.Dot), name_of(2), name_of(3), name_of(9))
    // Closures: what changes is shared, what does not is copied.
    var next = counter(10)
    print(next(), next())
    var seen = 0
    var add = fn(k: int) {
        seen += k
    }
    add(2)
    add(3)
    var outer = fn() -> int {
        var inner = fn() -> int {
            seen += 10
            return seen
        }
        return inner()
    }
    print(outer(), seen)
    var fixed = 5
    var times = fn(k: int) -> int {
        return k * fixed
    }
    print(times(3))
    // A box made from a `catch`.
    var got = risky(50) catch err {
        print("caught", err.message)
        -1
    }
    var bump = fn() {
        got += 1
    }
    bump()
    print(got)
    // Tasks share what they change.
    var done = chan<int>()
    var hits = 0
    fork {
        hits += 1
        done <- 1
    }
    <-done
    print(hits)
    var result = lowered(3) catch err {
        print("failed", err.message)
        0
    }
    print(result)
    var bad = lowered(20) or -1
    print(bad)
    // Shadowing a constant.
    var LIMIT = 3
    print(LIMIT)
}
