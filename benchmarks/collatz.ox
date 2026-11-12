// Longest Collatz chain below one million: branches, division, multiplication.
fn chain(start: int) -> int {
    var n = start
    var steps = 1
    while n != 1 {
        if n % 2 == 0 {
            n = n / 2
        } else {
            n = 3 * n + 1
        }
        steps += 1
    }
    return steps
}

fn main() {
    var best = 0
    var best_start = 0
    for start in 1..1000000 {
        var length = chain(start)
        if length > best {
            best = length
            best_start = start
        }
    }
    print(best_start, best)
}
