// error: E0102
interface Shape {
    fn area(self) -> float
}

struct Square {
    side: float
}

fn main() {
    let s: Shape = Square{side: 1.0}
    print(s.area())
}
