// Short-lived objects: allocation and release.
struct Point {
    x: int
    y: int
}

fn main() {
    var total = 0
    for i in 0..3000000 {
        var p = Point{x: i, y: 1}
        var label = "point {i}"
        var xs = [p.x, p.y, label.len()]
        total += xs[0] % 7 + xs[1]
    }
    print(total)
}
