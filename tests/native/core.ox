// Everything the native target supports so far.

fn fib(n: int) -> int {
    if n < 2 {
        return n
    }
    return fib(n - 1) + fib(n - 2)
}

fn classify(n: int) -> string {
    if n < 0 {
        return "negative"
    } else if n == 0 {
        return "zero"
    }
    return "positive"
}

fn is_prime(n: int) -> bool {
    if n < 2 {
        return false
    }
    var d = 2
    while d * d <= n {
        if n % d == 0 {
            return false
        }
        d += 1
    }
    return true
}

fn repeat(s: string, times: int) -> string {
    var out = ""
    for i in 0..times {
        out += s
    }
    return out
}

fn many(a: int, b: int, c: int, d: int, e: int, f: int, g: int, h: int) -> int {
    return a - b + c - d + e - f + g - h
}

fn main() {
    // integers
    print(1 + 2 * 3, (1 + 2) * 3, 10 / 3, -10 / 3, 10 % 3, -10 % 3)
    print(9007199254740991, -9007199254740991, 1000000 * 1000000)
    print(abs(-4), min(3, 9), max(3, 9), min(-1, -5))
    print(many(100, 1, 2, 3, 4, 5, 6, 7))

    // booleans and comparisons
    print(1 < 2, 2 <= 2, 3 > 4, 3 >= 4, 1 == 1, 1 != 1, !true)
    print(true && false, true || false, false || false, true && true)

    // strings
    var name = "Onyx"
    print("Hello, {name}! {1 + 1} + {true}")
    print(name + " " + "native", name.len(), "héllo".len(), "".len())
    print("a" == "a", "a" == "b", "a" != "b", "abc" < "abd", "b" > "abc", "ab" <= "ab")
    print(repeat("ab", 3), str(42) + str(false))
    print("tab\there \{braces\} \"quoted\"")

    // control flow
    var total = 0
    for i in 0..10 {
        if i == 3 {
            continue
        }
        if i == 8 {
            break
        }
        total += i
    }
    print("total", total)

    var n = 20
    n -= 5
    n *= 2
    n /= 4
    print(n)

    var x = 1
    {
        var x = x + 10
        print("inner", x)
    }
    print("outer", x)

    // functions and recursion
    print(fib(20), classify(-3), classify(0), classify(7))
    var primes = ""
    for i in 0..30 {
        if is_prime(i) {
            primes += "{i} "
        }
    }
    print(primes)
}
