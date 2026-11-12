// error: E0106
struct P {
    x: int
}

fn main() {
    let p = P{x: 1}
    print(p.y)
}
