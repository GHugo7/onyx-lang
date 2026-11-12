# 4. Structs and interfaces

## Structs

A struct groups named fields. Methods are written inside it and receive the
value as `self`.

```onyx
struct Player {
    name: string
    health: int

    fn hit(self, damage: int) {
        self.health = max(0, self.health - damage)
    }

    fn is_alive(self) -> bool {
        return self.health > 0
    }
}

fn main() {
    var p = Player{name: "Kai", health: 20}    // every field must be given
    p.hit(15)
    print(p.name, p.health, p.is_alive())
    print(p)                                   // Player{name: "Kai", health: 5}
}
```

Structs are shared, not copied: passing `p` to a function and changing a field
there changes the same player. Two structs are `==` when all their fields are
equal.

There are no constructors. When creating a value needs some logic, write an
ordinary function:

```onyx
struct Rect {
    w: float
    h: float
}

fn square(side: float) -> Rect {
    return Rect{w: side, h: side}
}

fn main() {
    print(square(2.0))
}
```

## Interfaces

An interface lists methods. A struct implements it automatically by having
those methods; there is no `implements` keyword.

```onyx
interface Animal {
    fn name(self) -> string
    fn sound(self) -> string
}

struct Dog {
    fn name(self) -> string { return "dog" }
    fn sound(self) -> string { return "woof" }
}

struct Robot {
    model: string

    fn name(self) -> string { return "robot {self.model}" }
    fn sound(self) -> string { return "beep" }
}

fn describe(a: Animal) -> string {
    return "the {a.name()} says {a.sound()}"
}

fn main() {
    var zoo: [Animal] = [Dog{}, Robot{model: "R2"}]
    for a in zoo {
        print(describe(a))
    }
}
```

If a struct is missing a method, the compiler says which one.

Next: [Error handling](05-error-handling.md)
