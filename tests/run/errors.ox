fn half(n: int) -> int! {
    if n % 2 != 0 {
        fail "{n} is odd"
    }
    return n / 2
}

fn quarter(n: int) -> int! {
    var h = half(n)?
    return half(h)?
}

fn check_positive(n: int) -> void! {
    if n < 0 {
        fail "negative"
    }
}

fn describe(n: int) -> string {
    var q = quarter(n) catch err {
        return "cannot quarter {n}: {err.message}"
    }
    return "{n} / 4 = {q}"
}

fn first_even(xs: [int]) -> int! {
    for x in xs {
        var h = half(x) catch e {
            continue
        }
        return h * 2
    }
    fail "no even number"
}

fn rethrow(n: int) -> int! {
    var v = half(n) catch err {
        fail err
    }
    return v
}

fn main() {
    print(half(10) or 0, half(7) or -1)
    print(describe(8), "|", describe(6), "|", describe(3))

    // catch producing a value
    var a = half(9) catch err {
        print("recovering from:", err)
        0
    }
    print(a)

    // catch on assignment and as a statement
    var b = 1
    b = half(5) catch e { 100 }
    b += half(4) catch e { 0 }
    print(b)
    check_positive(-1) catch e {
        print("statement catch:", e)
    }
    check_positive(1) catch e {
        print("never printed")
    }

    print(first_even([1, 3, 6, 8]) or -1, first_even([1, 3]) or -1)
    print(rethrow(3) or -7)
    print(1 + (half(4) or 0) * 2)

    // fallible lambdas
    var safe_div = fn(a: int, b: int) -> int! {
        if b == 0 { fail "division by zero" }
        return a / b
    }
    print(safe_div(6, 3) or 0, safe_div(1, 0) or -1)

    print(parse_int(" 12 ") or 0, parse_float("2.5") or 0.0, parse_int("1.5") or -1)
    print(read_file("/definitely/not/here") or "no file")
    print([1].first() or 0)
}
