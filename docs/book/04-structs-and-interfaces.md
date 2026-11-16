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

## Enums

An enum is a type whose values are one of several *variants*. A variant may
carry values of its own.

```onyx
enum Shape {
    Circle(radius: float)
    Rect(w: float, h: float)
    Empty
}

fn main() {
    var shapes = [Shape.Circle(2), Shape.Rect(3, 4.5), Shape.Empty]
    print(shapes)                              // [Shape.Circle(2.0), Shape.Rect(3.0, 4.5), Shape.Empty]
    print(Shape.Empty == Shape.Empty)          // true
}
```

The names inside the parentheses (`radius`, `w`) are for the reader; only
the types and their order matter, and they may be left out: `Circle(float)`.
A variant can carry values of the enum itself, which is how trees are made:

```onyx
enum Expr {
    Num(int)
    Add(Expr, Expr)
    Neg(Expr)
}

fn main() {
    print(Expr.Add(Expr.Num(1), Expr.Neg(Expr.Num(2))))
}
```

## match

`match` looks at a value and runs the case that fits. For an enum, a case
names a variant and gives names to what it carries:

```onyx
enum Shape {
    Circle(radius: float)
    Rect(w: float, h: float)
    Empty
}

fn area(s: Shape) -> float {
    match s {
        Circle(r) {
            return 3.14159 * r * r
        }
        Rect(w, h) {
            return w * h
        }
        Empty {
            return 0
        }
    }
}

fn main() {
    print(area(Shape.Rect(2, 3)))    // 6.0
}
```

Every variant must have its case: forget one and the program does not
compile, which is the point when a variant is added later. An `else` case
takes whatever is left. `_` stands for a carried value that is not needed,
and one case can serve several variants that carry nothing of interest:

```onyx
enum Token {
    Number(int)
    Word(string)
    Comma
    Stop
}

fn describe(t: Token) -> string {
    match t {
        Number(n) {
            return "the number {n}"
        }
        Word(_) {
            return "a word"
        }
        Comma, Stop {
            return "punctuation"
        }
    }
}

fn main() {
    print(describe(Token.Number(7)), describe(Token.Stop))
}
```

`match` also works on whole numbers, strings and booleans. Since there are
too many numbers and strings to list, those need an `else`:

```onyx
fn size(n: int) -> string {
    match n {
        0 {
            return "none"
        }
        1, 2, 3 {
            return "a few"
        }
        else {
            return "many"
        }
    }
}

fn main() {
    print(size(2), size(40))    // a few many
}
```

Next: [Error handling](05-error-handling.md)
