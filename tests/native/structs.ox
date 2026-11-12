// Structs, methods, interfaces and top-level variables on the native target.

const GREETING = "Hello"
var created = 0

struct Point {
    x: int
    y: int

    fn moved(self, dx: int, dy: int) -> Point {
        return Point{x: self.x + dx, y: self.y + dy}
    }

    fn manhattan(self) -> int {
        return abs(self.x) + abs(self.y)
    }
}

struct Player {
    name: string
    position: Point
    alive: bool

    fn describe(self) -> string {
        return "{self.name} at ({self.position.x}, {self.position.y})"
    }

    fn rename(self, name: string) {
        self.name = name
    }

    fn step(self) -> Player {
        self.position = self.position.moved(1, 0)
        return self
    }
}

interface Animal {
    fn name(self) -> string
    fn legs(self) -> int
}

struct Dog {
    fn name(self) -> string { return "dog" }
    fn legs(self) -> int { return 4 }
}

struct Bird {
    species: string

    fn name(self) -> string { return self.species }
    fn legs(self) -> int { return 2 }
}

struct Empty {
}

fn new_player(name: string) -> Player {
    created += 1
    return Player{name: name, position: Point{x: 0, y: 0}, alive: true}
}

fn describe(a: Animal) -> string {
    return "a {a.name()} has {a.legs()} legs"
}

fn pick(first: bool) -> Animal {
    if first {
        return Dog{}
    }
    return Bird{species: "crow"}
}

fn main() {
    // creation, fields, printing
    var p = Point{x: 3, y: -4}
    print(p, p.x, p.y, p.manhattan())
    print(Empty{}, Point{y: 1, x: 2})

    // methods returning new objects, chained
    var q = p.moved(1, 1).moved(10, 10)
    print(q, p.moved(0, 0) == p, q == p, q != p)

    // structs are shared, not copied
    var alice = new_player("Alice")
    var same = alice
    same.rename("Alicia")
    same.position.x = 7
    alice.position.y += 2
    print(alice.describe(), alice.name == same.name, alice == same)
    print(alice)

    // a method that returns self, and nested field updates
    alice.step().step().step()
    print(alice.position)
    alice.name += "!"
    alice.alive = !alice.alive
    print(alice.name, alice.alive)

    // replacing a field releases the old value
    for i in 0..3 {
        alice.position = Point{x: i, y: i * i}
    }
    print(alice.position)

    // interfaces
    var dog: Animal = Dog{}
    print(describe(dog), "|", describe(Bird{species: "owl"}))
    print(pick(true).name(), pick(false).name(), pick(false))
    print(pick(true) == pick(true), pick(true) == pick(false), dog == Dog{})

    // top-level variables
    var bob = new_player("Bob")
    print(GREETING + ", " + bob.name, "created:", created)
    created = 0
    print(created)
}
