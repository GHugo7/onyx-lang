// Floats in structs, lists, maps, interfaces and error handling.

struct Vec2 {
    x: float
    y: float
    tags: [float]

    fn length(self) -> float {
        return sqrt(self.x * self.x + self.y * self.y)
    }

    fn scale(self, k: float) {
        self.x *= k
        self.y *= k
        self.tags[0] += k
    }
}

interface Shape {
    fn area(self) -> float
}

struct Circle {
    r: float

    fn area(self) -> float {
        return 3.14159 * self.r * self.r
    }
}

struct Box {
    w: int
    h: float

    fn area(self) -> float {
        return self.w * self.h
    }
}

var g_scale = 2.0
var g_hist: [float] = []

fn mean(xs: [float]) -> float {
    var total = 0.0
    for x in xs {
        total += x
    }
    return total / xs.len()
}

fn safe_div(a: float, b: float) -> float! {
    if b == 0.0 {
        fail "division by zero"
    }
    return a / b
}

fn main() {
    var v = Vec2{x: 3, y: 4.0, tags: [1, 2.5]}
    print(v, v.length(), [v.x, v.y], {"a": 1.0, "b": 2.5})
    v.scale(g_scale)
    v.x -= 1
    v.tags[1] /= 2
    print(v, v.tags.join(" | "), "{v.tags} {v.x}")
    var shapes: [Shape] = [Circle{r: 1.0}, Box{w: 2, h: 3.5}, Circle{r: 2}]
    var total = 0.0
    for s in shapes {
        total += s.area()
        g_hist.push(s.area())
    }
    print(total, shapes, g_hist, mean(g_hist), mean([1, 2, 3, 4]))
    g_scale *= 1.5
    g_scale += 1
    print(g_scale, safe_div(1, 4) or -1.0, safe_div(1.0, 0.0) or -1, [1.5] == [1.5], [0.0] == [-0.0], v == v)
    safe_div(3, 0) catch err {
        print("caught", err)
    }
    var ratios: map<string, float> = {}
    ratios["half"] = 1
    ratios["half"] /= 2
    ratios["third"] = 1.0 / 3
    print(ratios, ratios["half"] + 1, ratios.values(), ratios.get("x") or 0)
    var grid: [[float]] = [[1, 2], [3.5]]
    grid[0][1] *= 2.5
    print(grid, grid[0][1] > 4, min(grid[0][0], grid[1][0]), max(2, grid[1][0]), abs(-grid[1][0]))
    var i = 0
    var acc = 1.0
    while i < 20 {
        acc = acc * 1.5 - i / 4 + float(i) / 4
        i += 1
    }
    print(acc, int(acc), floor(acc), round(acc), acc > 1000.0, -acc, 10 - acc, 2 / acc)
}
