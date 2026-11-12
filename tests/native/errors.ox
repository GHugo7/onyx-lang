// Error handling on the native target: `!`, `?`, `or`, `catch` and `fail`.

struct Account {
    owner: string
    balance: int

    fn withdraw(self, amount: int) -> int! {
        if amount > self.balance {
            fail "{self.owner} only has {self.balance}, cannot withdraw {amount}"
        }
        self.balance -= amount
        return self.balance
    }

    fn check(self) -> void! {
        if self.balance < 0 {
            fail "negative balance"
        }
    }
}

interface Source {
    fn next(self) -> int!
}

struct Countdown {
    left: int

    fn next(self) -> int! {
        if self.left == 0 {
            fail "countdown finished"
        }
        self.left -= 1
        return self.left
    }
}

fn half(n: int) -> int! {
    if n % 2 != 0 {
        fail "{n} is odd"
    }
    return n / 2
}

fn quarter(n: int) -> int! {
    return half(half(n)?)?
}

fn label(n: int) -> string! {
    if n < 0 {
        fail "negative"
    }
    return "n{n}"
}

fn describe(n: int) -> string {
    var q = quarter(n) catch err {
        return "cannot quarter {n}: {err.message}"
    }
    return "{n} / 4 = {q}"
}

// `?` in the middle of expressions: what was computed before it must be
// released when the function leaves early.
fn combine(a: int, b: int) -> string! {
    var names = ["x" + str(a), label(a)?, "y" + str(b), label(b)?]
    var text = "{names.join("-")}:" + label(a + b)? + ":{half(a * 2)? + half(b * 2)?}"
    var both = Account{owner: label(a)? + "&" + label(b)?, balance: half((a + b) * 2)? + 1}
    return text + "/" + both.owner + "/{both.balance}/{[label(a)?, label(b)?].len()}"
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

fn sum_halves(xs: [int]) -> int! {
    var total = 0
    for x in xs {
        total += half(x)?
    }
    return total
}

fn rethrow(n: int) -> int! {
    var v = half(n) catch err {
        fail err
    }
    return v
}

fn wrap(n: int) -> int! {
    var v = half(n) catch err {
        fail "wrapped: " + err.message
    }
    return v
}

fn guarded(n: int) -> bool! {
    return n > 0 && half(n)? > 2 || n == -4 && half(n)? == -2
}

fn or_chain(n: int) -> int! {
    return half(n) or half(n + 1)? * 10
}

fn drain(source: Source) -> int {
    var total = 0
    var steps = 0
    while steps < 100 {
        var v = source.next() catch e {
            break
        }
        total += v
        steps += 1
    }
    return total * 100 + steps
}

fn while_try(limit: int) -> int! {
    var n = 64
    var steps = 0
    while half(n)? >= limit {
        n = half(n)?
        steps += 1
    }
    return steps
}

fn finish(n: int) -> string {
    return label(n) catch err {
        "failed: {err}"
    }
}

// `?` written inside the subject of an `or` or a `catch` still leaves the
// function: those only handle the failure of their own subject.
fn escape(n: int) -> int! {
    var a = parse_int("{half(n)?}x") or -2
    var b = parse_int("{half(n + 2)?}") catch err {
        -3
    }
    return a + b
}

fn deep(n: int) -> int! {
    return half((half(parse_int("{half(n)?}0") or 1) or 2) * 2) or 3
}

fn main() {
    print(half(10) or 0, half(7) or -1, quarter(12) or -1, quarter(10) or -1, quarter(7) or -1)
    print(describe(8), "|", describe(6), "|", describe(3))

    // catch producing a value, with and without using the error
    var a = half(9) catch err {
        print("recovering from:", err)
        0
    }
    var b = label(-1) catch err {
        "<" + err.message + ">"
    }
    print(a, b, finish(3), finish(-3))

    // catch on assignment and as a statement
    var c = 1
    c = half(5) catch e { 100 }
    c += half(4) catch e { 0 }
    var words = ["a"]
    words[0] = label(7) catch e { "none" }
    words[0] += label(-7) catch e { "!" }
    print(c, words)
    var account = Account{owner: "ana", balance: 50}
    account.balance = half(31) catch e { 0 - account.balance }
    account.check() catch e {
        print("statement catch:", e)
    }
    account.balance = 50
    account.check() catch e {
        print("never printed")
    }

    // methods that can fail
    print(account.withdraw(20) or -1, account.withdraw(100) or -1, account.balance)
    account.withdraw(1000) catch err {
        print(err)
    }

    // `?` in the middle of expressions
    print(combine(3, 4) or "failed", combine(3, -4) or "failed", combine(-3, 4) or "failed", combine(1, 2) or "failed")
    print(first_even([1, 3, 6, 8]) or -1, first_even([1, 3]) or -1, sum_halves([2, 4, 6]) or -1, sum_halves([2, 5, 6]) or -1)
    print(rethrow(3) or -7, rethrow(8) or -7, 1 + (half(4) or 0) * 2)
    var message = wrap(5) catch err { -1 }
    wrap(7) catch err {
        print(err, err.message.len(), message)
    }
    print(guarded(8) or false, guarded(4) or false, guarded(-4) or false, guarded(7) or true, guarded(-3) or true)
    print(or_chain(8) or -1, or_chain(7) or -1, while_try(4) or -1, while_try(3) or -1)

    // through an interface
    print(drain(Countdown{left: 5}), drain(Countdown{left: 0}))

    // built-in operations that can fail
    var stack = [1, 2, 3]
    print(stack.pop() or 0, stack.first() or 0, stack.last() or 0, stack)
    stack.clear()
    print(stack.pop() or -1, stack.first() or -1, stack.last() or -1)
    stack.pop() catch err {
        print("pop:", err)
    }
    var names = ["x", "y"]
    print(names.pop() or "", names.first() or "", names.last() or "", names)
    print(parse_int("42") or 0, parse_int(" -17 ") or 0, parse_int("+5") or 0, parse_int("abc") or -1, parse_int("") or -1, parse_int("1.5") or -1, parse_int("12x") or -1, parse_int("9007199254740991") or 0)
    parse_int("four") catch err {
        print(err)
    }

    // `?` under `or` and `catch`
    print(escape(4) or -100, escape(3) or -100, escape(5) or -100, deep(4) or -100, deep(3) or -100)
    escape(7) catch err {
        print("escape:", err)
    }
}
