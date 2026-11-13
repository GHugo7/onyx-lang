// Three million calls through function values, and map / filter / sort_by
// over a list of 300 000 numbers.

fn compose(f: fn(int) -> int, g: fn(int) -> int) -> fn(int) -> int {
    return fn(n: int) -> int {
        return g(f(n))
    }
}

fn main() {
    var offset = 3
    var add = fn(n: int) -> int {
        return n + offset
    }
    var triple = fn(n: int) -> int {
        return n * 3 % 1000003
    }
    var both = compose(add, triple)
    var total = 0
    for i in 0..1000000 {
        total = both(total + i) % 1000003
    }

    var numbers: [int] = []
    for i in 0..300000 {
        numbers.push(i * 7919 % 100003)
    }
    var calls = 0
    var kept = numbers.map(fn(n: int) -> int {
        calls += 1
        return n * 2 + offset
    }).filter(fn(n: int) -> bool {
        return n % 3 == 0
    }).sort_by(fn(n: int) -> int {
        return -n
    })
    print(total, calls, kept.len(), kept[0], kept[kept.len() - 1])
}
