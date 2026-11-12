// error: E0102
interface Shape {
    fn area(self) -> float
}

struct Square {
    side: float
}

fn main() {
    var s: Shape = Square{side: 1.0}
    print(s.area())
}
