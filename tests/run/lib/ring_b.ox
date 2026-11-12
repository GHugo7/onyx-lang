import "ring_c"

const offset = 100

fn chain(n: int) -> int {
    return ring_c.chain(n) + 10
}
