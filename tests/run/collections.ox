struct Point {
    x: int
    y: int
}

fn main() {
    // lists
    let xs = [5, 3, 8, 1]
    xs.push(4)
    print(xs, xs.len(), xs[0], xs.contains(8), xs.index_of(8), xs.index_of(99))
    print(xs.sort(), xs.reverse(), xs.slice(1, 3))
    xs[0] = 50
    xs[1] += 1
    xs.insert(1, 7)
    print(xs, xs.remove(0), xs)
    print(xs.pop() or -1, xs.first() or -1, xs.last() or -1)
    xs.clear()
    print(xs, xs.pop() or -1)

    let words = "the quick brown fox".split(" ")
    print(words.map(fn(w: string) -> int { return w.len() }))
    print(words.filter(fn(w: string) -> bool { return w.len() > 3 }))
    print(words.sort_by(fn(w: string) -> int { return w.len() }))
    print(words.join("-"))
    let mixed = [1, 2.5]
    print(mixed[0] + mixed[1])
    let grid = [[1, 2], [3, 4]]
    grid[1][0] = 30
    print(grid, grid[1][0])

    // strings
    let s = "  Hello, World  "
    print(s.trim().upper(), s.trim().lower(), s.trim().len())
    print("hello".contains("ell"), "hello".starts_with("he"), "hello".ends_with("lo"))
    print("a-b-c".replace("-", "+"), "hello".index_of("l"), "hello".slice(1, 3), "ab".repeat(3))
    print("héllo".chars(), "abc"[1])
    for c in "hey" {
        print(c)
    }

    // maps
    let ages: map<string, int> = {}
    ages["a"] = 1
    ages["b"] = 2
    ages["a"] += 10
    print(ages, ages.len(), ages.has("a"), ages.has("z"), ages["a"])
    print(ages.get("b") or 0, ages.get("zzz") or -1)
    ages.remove("a")
    print(ages.keys(), ages.values())
    let squares = {1: 1, 2: 4, 3: 9}
    let total = 0
    for k in squares {
        total += squares[k]
    }
    print(total)

    // structural equality
    let p = Point{x: 1, y: 2}
    let q = Point{y: 2, x: 1}
    print(p == q, p != q, [1, 2] == [1, 2], [p] == [q], {"k": [1]} == {"k": [1]})
    q.x = 9
    print(p == q, q)

    // ranges
    let r = 2..5
    for i in r {
        print(i)
    }
}
