// Enums and match.

enum Shape {
    Circle(radius: float)
    Rect(w: float, h: float)
    Label(string, [int])
    Empty
}

enum Expr {
    Num(int)
    Add(Expr, Expr)
    Mul(Expr, Expr)
    Neg(Expr)
    Var(name: string)
}

enum Color {
    Red
    Green
    Blue
}

enum Token {
    Number(int)
    Word(string)
    Stop
}

struct Pixel {
    color: Color
    at: [int]
}

fn area(s: Shape) -> float {
    match s {
        Circle(r) {
            return 3.0 * r * r
        }
        Rect(w, h) {
            return w * h
        }
        Label(_, _), Empty {
            return 0
        }
    }
}

fn eval(e: Expr, env: map<string, int>) -> int! {
    match e {
        Num(n) {
            return n
        }
        Add(a, b) {
            return eval(a, env)? + eval(b, env)?
        }
        Mul(a, b) {
            return eval(a, env)? * eval(b, env)?
        }
        Neg(inner) {
            return -eval(inner, env)?
        }
        Var(name) {
            return env.get(name) catch err {
                fail "unknown variable {name}"
            }
        }
    }
}

fn show(e: Expr) -> string {
    match e {
        Num(n) {
            return str(n)
        }
        Add(a, b) {
            return "({show(a)} + {show(b)})"
        }
        Mul(a, b) {
            return "{show(a)} * {show(b)}"
        }
        Neg(inner) {
            return "-" + show(inner)
        }
        Var(name) {
            return name
        }
    }
}

fn name_of(c: Color) -> string {
    var name = "?"
    match c {
        Red {
            name = "red"
        }
        Green, Blue {
            name = "cool"
        }
    }
    return name
}

fn classify(n: int) -> string {
    match n {
        0 {
            return "zero"
        }
        1, 2, 3 {
            return "small"
        }
        -1 {
            return "minus one"
        }
        else {
            if n < 0 {
                return "negative"
            }
            return "big"
        }
    }
}

fn tokens(text: string) -> [Token] {
    var out: [Token] = []
    for word in text.split(" ") {
        match word {
            "" {
                continue
            }
            "." {
                out.push(Token.Stop)
                break
            }
            else {
                var n = parse_int(word) catch err {
                    out.push(Token.Word(word))
                    continue
                }
                out.push(Token.Number(n))
            }
        }
    }
    return out
}

fn main() {
    // making and showing values
    var shapes = [Shape.Circle(2), Shape.Rect(3, 4.5), Shape.Label("hi", [1, 2]), Shape.Empty]
    print(shapes)
    for s in shapes {
        print(area(s), s)
    }
    print(Shape.Empty == Shape.Empty, Shape.Circle(1) == Shape.Circle(1.0), Shape.Circle(1) == Shape.Circle(2), Shape.Empty != Shape.Rect(1, 1))
    print(Shape.Label("a", [1]) == Shape.Label("a", [1]), Shape.Label("a", [1]) == Shape.Label("a", [2]))

    // a tree
    var tree = Expr.Add(Expr.Num(2), Expr.Mul(Expr.Var("x"), Expr.Neg(Expr.Num(3))))
    var env = {"x": 5}
    print(show(tree), "=", eval(tree, env) or -1)
    print(eval(Expr.Var("y"), env) or -999, tree)
    eval(Expr.Add(Expr.Num(1), Expr.Var("nope")), env) catch err {
        print("error:", err)
    }

    // plain variants, in structs, maps and lists
    var pixel = Pixel{color: Color.Green, at: [1, 2]}
    print(name_of(Color.Red), name_of(pixel.color), name_of(Color.Blue), pixel, pixel.color == Color.Green)
    var votes: map<string, Color> = {"a": Color.Red, "b": Color.Blue}
    votes["c"] = Color.Red
    var reds = 0
    for who in votes.keys() {
        match votes[who] {
            Red {
                reds += 1
            }
            else {
            }
        }
    }
    print(reds, votes)

    // match on numbers, strings and booleans
    print(classify(0), classify(2), classify(-1), classify(-7), classify(100))
    print(tokens("add 2 and  3 . ignored"), tokens(""))
    var flags = [true, false]
    for f in flags {
        match f {
            true {
                print("yes")
            }
            false {
                print("no")
            }
        }
    }

    // match in loops, with values that are kept or changed
    var total = 0
    var words: [string] = []
    for t in tokens("7 apples and 12 pears") {
        match t {
            Number(n) {
                total += n
                n = 0
            }
            Word(w) {
                words.push(w.upper())
            }
            Stop {
                break
            }
        }
    }
    print(total, words)

    // nested match, and a lambda in a case
    var pairs = [Expr.Add(Expr.Num(1), Expr.Num(2)), Expr.Neg(Expr.Var("z")), Expr.Num(9)]
    var seen: [string] = []
    for p in pairs {
        match p {
            Add(left, right) {
                match left {
                    Num(n) {
                        var describe = fn() -> string {
                            return "starts with {n}, then {show(right)}"
                        }
                        seen.push(describe())
                    }
                    else {
                        seen.push("other sum")
                    }
                }
            }
            Neg(inner) {
                seen.push("negated " + show(inner))
            }
            else {
                seen.push("plain " + show(p))
            }
        }
    }
    print(seen)
}
