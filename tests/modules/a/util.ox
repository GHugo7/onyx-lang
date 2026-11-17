import "../b/util" as other
import "deep/leaf.ox"

struct Point {
    x: int
    y: int
}

enum Kind {
    One
    Two(Point)
}

var _secret = 3
var shared = other.value() + _secret

fn make(x: int) -> Point {
    return Point{x: x, y: leaf.depth}
}

fn _hidden() -> int {
    return 1
}
