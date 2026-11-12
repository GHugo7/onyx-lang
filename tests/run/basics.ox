const LIMIT = 3
let calls = 0

fn add(a: int, b: int) -> int {
    calls += 1
    return a + b
}

fn classify(n: int) -> string {
    if n < 0 {
        return "negative"
    } else if n == 0 {
        return "zero"
    } else {
        return "positive"
    }
}

fn main() {
    // arithmetic
    print(1 + 2 * 3, (1 + 2) * 3, 10 / 3, -10 / 3, 10 % 3, 10.0 / 4)
    print(2.0, 2.5, 1 + 0.5, float(3), int(3.9), int(-3.9))
    print(abs(-4), abs(-2.5), min(3, 9), max(2, 7.5), sqrt(16.0), pow(2.0, 10.0))
    print(floor(2.7), ceil(2.1), round(2.5))
    print(1 < 2, 2 <= 2, "a" < "b", 1 == 1.0, !true, true && false, true || false)

    // shadowing in nested scopes
    let x = 1
    {
        let x = x + 10
        print("inner", x)
    }
    print("outer", x)

    // while, break, continue
    let i = 0
    let seen: [int] = []
    while true {
        i += 1
        if i == 2 { continue }
        if i > LIMIT + 2 { break }
        seen.push(i)
    }
    print(seen)

    // compound assignment
    let n = 20
    n -= 5
    n *= 2
    n /= 4
    print(n)
    let f = 1.0
    f /= 4
    print(f)
    let s = "ab"
    s += "cd"
    print(s)

    print(classify(-5), classify(0), classify(5))
    print(add(1, 2), add(3, 4), "calls:", calls)

    // JavaScript reserved words are fine as names
    let new = 1
    let class = 2
    let function = new + class
    print(function)

    // escapes and nested interpolation
    print("tab\there \{braces\} \"quoted\" {"nested {1 + 1}"}")
}
