// Calls through an interface.
interface Shape {
    fn area(self) -> int
}

struct Square {
    side: int

    fn area(self) -> int {
        return self.side * self.side
    }
}

struct Rect {
    w: int
    h: int

    fn area(self) -> int {
        return self.w * self.h
    }
}

fn main() {
    var shapes: [Shape] = []
    for i in 0..1000 {
        if i % 3 == 0 {
            shapes.push(Rect{w: i % 7 + 1, h: i % 5 + 1})
        } else {
            shapes.push(Square{side: i % 9 + 1})
        }
    }
    var total = 0
    for round in 0..5000 {
        for s in shapes {
            total += s.area()
        }
    }
    print(total)
}
