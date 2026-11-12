// Lists on the native target.

struct Item {
    name: string
    price: int
}

struct Node {
    label: string
    children: [Node]

    fn count(self) -> int {
        var n = 1
        for c in self.children {
            n += c.count()
        }
        return n
    }
}

fn squares(n: int) -> [int] {
    var out: [int] = []
    for i in 0..n {
        out.push(i * i)
    }
    return out
}

fn total(items: [Item]) -> int {
    var sum = 0
    for item in items {
        sum += item.price
    }
    return sum
}

fn names(items: [Item]) -> [string] {
    var out: [string] = []
    for item in items {
        out.push(item.name)
    }
    return out
}

fn first_big(xs: [int], limit: int) -> int {
    for x in xs {
        if x > limit {
            return x
        }
    }
    return -1
}

fn main() {
    // integers
    var xs = [5, 3, 8, 1]
    xs.push(4)
    print(xs, xs.len(), xs[0], xs[4], xs.contains(8), xs.contains(9), xs.index_of(8), xs.index_of(99))
    print(xs.sort(), xs.reverse(), xs.slice(1, 3), xs.slice(-2, 99), xs.slice(3, 1))
    xs[0] = 50
    xs[1] += 1
    xs[2] *= 2
    xs.insert(1, 7)
    xs.insert(xs.len(), 9)
    print(xs, xs.remove(0), xs)
    xs.clear()
    print(xs, xs.len(), squares(6), squares(0))
    print([1, 2] == [1, 2], [1, 2] == [1, 3], [1, 2] != [1, 2, 3], squares(3) == [0, 1, 4])

    // growing past the initial capacity many times
    var big: [int] = []
    for i in 0..1000 {
        big.push(i)
    }
    var sum = 0
    for v in big {
        sum += v
    }
    print(big.len(), sum, big[999], first_big(big, 500), first_big(big, 5000))

    // strings
    var words = ["pear", "apple", "fig"]
    words.push("kiwi" + "!")
    print(words, words.join(", "), words.sort(), words.contains("fig"), words.index_of("kiwi!"))
    words[0] = words[0] + "s"
    words[1] += "s"
    print(words[0], words[1], words.remove(2), words, [1, 2, 3].join("-"))
    var quoted = ["say \"hi\"", "tab\there", "back\\slash"]
    print(quoted)

    // structs in lists
    var cart = [Item{name: "pen", price: 2}, Item{name: "book", price: 12}]
    cart.push(Item{name: "lamp", price: 30})
    print(total(cart), names(cart), cart[1], cart[2].name)
    cart[0].price = 3
    cart[1] = Item{name: "notebook", price: 5}
    print(cart, cart.contains(Item{name: "lamp", price: 30}), cart.index_of(Item{name: "none", price: 0}))

    // nested lists and loops with break / continue
    var grid = [[1, 2, 3], [4, 5, 6], [7, 8, 9]]
    grid[1][1] = 50
    var diagonal: [int] = []
    for row in grid {
        for cell in row {
            if cell % 2 == 0 {
                continue
            }
            if cell > 7 {
                break
            }
            diagonal.push(cell)
        }
    }
    print(grid, grid[1][1], grid[2].len(), diagonal)

    // changing a list while walking it
    var queue = [1, 2, 3]
    var seen: [int] = []
    for q in queue {
        seen.push(q)
        if q < 3 {
            queue.push(q + 10)
        }
    }
    print(seen)

    // a tree: structs holding lists of structs
    var tree = Node{label: "root", children: [
        Node{label: "a", children: []},
        Node{label: "b", children: [Node{label: "c", children: []}]},
    ]}
    tree.children[0].children.push(Node{label: "d", children: []})
    print(tree.count(), tree.children[1].children[0].label, tree.children[0])

    // sorting: stable, with duplicates and negatives
    print([3, -1, 2, -1, 0, 3, -7].sort(), ["b", "a", "c", "a", ""].sort(), squares(1).sort())
}
