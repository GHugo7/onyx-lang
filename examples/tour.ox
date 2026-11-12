// A quick tour of Onyx.

struct Player {
    name: string
    score: int

    fn describe(self) -> string {
        return "{self.name} ({self.score} pts)"
    }

    fn add(self, points: int) {
        self.score += points
    }
}

interface Shape {
    fn area(self) -> float
    fn name(self) -> string
}

struct Circle {
    radius: float

    fn area(self) -> float {
        return 3.14159 * self.radius * self.radius
    }
    fn name(self) -> string {
        return "circle"
    }
}

struct Rect {
    w: float
    h: float

    fn area(self) -> float {
        return self.w * self.h
    }
    fn name(self) -> string {
        return "rectangle"
    }
}

const MAX_SCORE = 100

fn best(players: [Player]) -> Player! {
    if players.len() == 0 {
        fail "no players"
    }
    var top = players[0]
    for p in players {
        if p.score > top.score {
            top = p
        }
    }
    return top
}

fn fib(n: int) -> int {
    if n < 2 {
        return n
    }
    return fib(n - 1) + fib(n - 2)
}

fn main() {
    // Variables and types
    var count: int = 3
    var ratio = 0.75
    var greeting = "hi"
    print("count={count} ratio={ratio} greeting={greeting}")
    print("7 / 2 = {7 / 2}, 7.0 / 2 = {7.0 / 2}, 7 % 2 = {7 % 2}")

    // Structs and methods
    var alex = Player{name: "Alex", score: 40}
    var sam = Player{name: "Sam", score: 75}
    alex.add(10)
    print(alex.describe())
    print(alex)

    // Lists, maps, loops
    var players = [alex, sam]
    var names = players.map(fn(p: Player) -> string { return p.name })
    print("players: {names.join(", ")}")

    var ages: map<string, int> = {"Alex": 31, "Sam": 27}
    ages["Léo"] = 19
    for name in ages {
        print("{name} is {ages[name]}")
    }

    var total = 0
    for i in 0..5 {
        total += i
    }
    print("sum 0..5 = {total}, fib(20) = {fib(20)}, max = {MAX_SCORE}")

    // Interfaces
    var shapes: [Shape] = [Circle{radius: 1.0}, Rect{w: 2.0, h: 3.5}]
    for s in shapes {
        print("{s.name()} has area {s.area()}")
    }

    // Errors: `or` gives a default, `catch` handles, `?` passes it on
    var winner = best(players) catch err {
        print("error: {err}")
        return
    }
    print("winner: {winner.describe()}")

    var empty: [Player] = []
    var nobody = best(empty) or Player{name: "nobody", score: 0}
    print("fallback: {nobody.name}")

    var n = parse_int("42") or 0
    var bad = parse_int("abc") or -1
    print("parsed {n} and {bad}")

    // Concurrency: fork + channels
    var ch = chan<string>()
    for id in 1..4 {
        fork {
            sleep(10 * (4 - id))
            ch <- "task {id} done"
        }
    }
    for i in 0..3 {
        print(<-ch)
    }

    // Lambdas and closures
    var counter = 0
    var bump = fn() -> int {
        counter += 1
        return counter
    }
    bump()
    bump()
    print("counter = {counter}")
    var evens = [1, 2, 3, 4, 5, 6].filter(fn(x: int) -> bool { return x % 2 == 0 })
    print(evens)
}

check "fib works" {
    expect(fib(10) == 55)
}

check "best fails on an empty list" {
    var empty: [Player] = []
    var p = best(empty) or Player{name: "none", score: -1}
    expect(p.score == -1)
}
