// Files that import each other in a ring, one of them importing this file back.
// Top-level variables only depend on what is already initialised.
import "lib/ring_a"
import "lib/ring_c" as c

const BASE = 10
var doubled = twice(BASE)
var sorted = ["b", "c", "a"].sort()
var lengths = sorted.map(fn(w: string) -> int { return w.len() + BASE })
var late = 0

fn twice(n: int) -> int {
    return n * 2
}

fn uses_late() -> int {
    return late + doubled
}

fn main() {
    print(doubled, sorted, lengths, uses_late())
    late = 5
    print(uses_late())
    print(ring_a.chain(3), c.back_to_entry(4), c.steps, ring_a.total())
    ring_a.record("x")
    c.note("y")
    print(ring_a.log, ring_a.total())
}
