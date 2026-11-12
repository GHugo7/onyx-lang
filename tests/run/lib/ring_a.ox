import "ring_b"

var log: [string] = []

fn record(entry: string) {
    log.push(entry)
}

fn chain(n: int) -> int {
    return ring_b.chain(n) + 1
}

fn total() -> int {
    return log.len() + ring_b.offset
}
