interface Animal {
    fn name(self) -> string
    fn speak(self) -> string
}

struct Dog {
    fn name(self) -> string { return "dog" }
    fn speak(self) -> string { return "woof" }
}

struct Cat {
    lives: int
    fn name(self) -> string { return "cat" }
    fn speak(self) -> string {
        self.lives -= 1
        return "meow ({self.lives} lives left)"
    }
}

struct Counter {
    value: int
    step: int
    on_change: fn(int)

    fn tick(self) -> Counter {
        self.value += self.step
        self.on_change(self.value)
        return self
    }
}

struct Node {
    label: string
    children: [Node]

    fn count(self) -> int {
        var n = 1
        for c in self.children {
            n += c.count()
        }
        return n
    }
}

fn intro(a: Animal) -> string {
    return "the {a.name()} says {a.speak()}"
}

fn apply(f: fn(int) -> int, times: int, start: int) -> int {
    var v = start
    for i in 0..times {
        v = f(v)
    }
    return v
}

fn make_adder(n: int) -> fn(int) -> int {
    return fn(x: int) -> int { return x + n }
}

fn double(x: int) -> int {
    return x * 2
}

fn main() {
    var cat = Cat{lives: 9}
    var pets: [Animal] = [Dog{}, cat]
    for p in pets {
        print(intro(p))
    }
    print(cat.lives)

    var log: [int] = []
    var c = Counter{value: 0, step: 5, on_change: fn(v: int) { log.push(v) }}
    c.tick().tick().tick()
    print(c.value, log)

    var tree = Node{label: "root", children: [
        Node{label: "a", children: []},
        Node{label: "b", children: [Node{label: "c", children: []}]},
    ]}
    print(tree.count(), tree.children[1].children[0].label)

    print(apply(double, 3, 1), apply(make_adder(10), 2, 0))
    var fs = [double, make_adder(1)]
    print(fs[0](21), fs[1](41))
    var half: float = 1
    print(half / 2)
}
