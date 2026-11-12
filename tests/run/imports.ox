import "lib/geometry" as geo
import "lib/numbers"

struct Square {
    side: float

    fn area(self) -> float {
        return numbers.square(self.side)
    }
}

// Same name as a function of the imported module: no conflict.
fn origin() -> string {
    return "my own origin"
}

fn main() {
    // functions, constants and variables of a module
    print(numbers.double(21), numbers.square(1.5), geo.PI)
    print(origin(), geo.origin(), numbers.origin_x())

    // types of a module: annotations, literals, methods
    var p: geo.Point = geo.Point{x: 3, y: 4}
    var q = p.moved(1, 1)
    print(p, q, geo.distance(p, geo.origin()))
    var points: [geo.Point] = [p, q]
    print(points.len())

    // a local struct implementing a module's interface
    var shapes: [geo.Shape] = [geo.unit_circle(), Square{side: 2.0}, geo.unit_circle()]
    for s in shapes {
        print(s.area())
    }
    print("created:", geo.shapes_created)
    geo.shapes_created = 0
    print("reset:", geo.shapes_created)

    // module functions as values, async and fallible ones
    var f = numbers.double
    print(f(4), [1, 2].map(numbers.double), numbers.slow_triple(5))
    print(geo.checked_radius(2.0) or 0.0, geo.checked_radius(-1.0) or 0.0)

    // a local variable hides a module name
    var numbers = [7, 8]
    print(numbers.len())
}

check "module functions work in checks" {
    expect(geo.origin().x == 0)
}
