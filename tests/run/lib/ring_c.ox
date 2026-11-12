import "ring_a"
import "../cycles" as entry

var steps = 3 * 4

fn chain(n: int) -> int {
    if n <= 0 {
        return 0
    }
    return ring_a.chain(n - 1) + 100
}

fn back_to_entry(n: int) -> int {
    return entry.twice(n) + steps
}

fn note(text: string) {
    ring_a.record("c says " + text)
}
