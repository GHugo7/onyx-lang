import "numbers"

const PI = 3.14159
var shapes_created = 0

interface Shape {
    fn area(self) -> float
}

struct Point {
    x: int
    y: int

    fn moved(self, dx: int, dy: int) -> Point {
        return Point{x: self.x + dx, y: self.y + dy}
    }
}

struct Circle {
    center: Point
    radius: float

    fn area(self) -> float {
        return PI * numbers.square(self.radius)
    }
}

fn origin() -> Point {
    return Point{x: 0, y: 0}
}

fn unit_circle() -> Circle {
    shapes_created += 1
    return Circle{center: origin(), radius: 1.0}
}

fn distance(a: Point, b: Point) -> float {
    var dx = a.x - b.x
    var dy = a.y - b.y
    return sqrt(float(_sum_of_squares(dx, dy)))
}

fn _sum_of_squares(a: int, b: int) -> int {
    return a * a + b * b
}

fn checked_radius(r: float) -> float! {
    if r < 0 {
        fail "negative radius"
    }
    return r
}

check "checks of imported files are not run" {
    expect(false)
}
