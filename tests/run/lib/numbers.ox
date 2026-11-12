// Imported by both imports.ox and geometry.ox, and imports geometry back:
// circular imports are allowed.
import "geometry"

fn square(x: float) -> float {
    return x * x
}

fn double(n: int) -> int {
    return n * 2
}

fn origin_x() -> int {
    return geometry.origin().x
}

fn slow_triple(n: int) -> int {
    sleep(1)
    return n * 3
}
