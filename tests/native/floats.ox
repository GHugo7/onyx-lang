// Float arithmetic, comparisons, conversions and text.

fn area(r: float) -> float {
    return 3.141592653589793 * r * r
}

fn main() {
    var x = 1.5
    var y = 2.25
    print(x + y, x - y, x * y, x / y, -x, x % y, 7.5 % 2.0, -7.5 % 2.0)
    print(x < y, x <= y, x > y, x >= y, x == y, x != y, x == 1.5)
    var n = 3
    var z: float = n
    print(z, z / 2, n / 2, 2 * x, x + 1, float(n) / 2.0, int(7.9), int(-7.9))
    print(area(2.0), area(1), sqrt(2.0), sqrt(16), abs(-2.5), min(1.5, 2), max(1, 2.5))
    print(0.1 + 0.2, 1.0 / 3.0, 100.0, 1e21, 1e-7, 123456789.125, 0.000001, 1.5e300, 5e-324, 1.7976931348623157e308)
    print(floor(2.7), ceil(2.1), round(2.5), round(-2.5), floor(-2.7), ceil(-2.1), round(0.49999999999999994))
    var total = 0.0
    for i in 0..10 {
        total += 0.1
    }
    print(total, total == 1.0, "{total} and {x}", str(y) + "!")
    var xs = [1.5, 2, 0.25]
    xs.push(4)
    print(xs, xs.len(), xs[1] + xs[2], xs.sort(), xs.contains(2.0), xs.index_of(0.25))
    if x < 2.0 && y > 2.0 {
        print("ok")
    }
    var w = 10.0
    while w > 0.5 {
        w /= 2.0
    }
    print(w, 1.0 / 0.0, -1.0 / 0.0, 0.0 / 0.0, 0.0 / 0.0 == 0.0 / 0.0)
}
