// Maps on the native target.

struct Stock {
    name: string
    count: int
}

fn tally(words: [string]) -> map<string, int> {
    var counts: map<string, int> = {}
    for w in words {
        counts[w] = (counts.get(w) or 0) + 1
    }
    return counts
}

fn lookup(prices: map<string, int>, item: string) -> int! {
    return prices.get(item)? * 2
}

fn describe(m: map<int, string>) -> string {
    var out = ""
    for k in m {
        out += "{k}={m[k]};"
    }
    return out
}

fn main() {
    // string keys
    var ages: map<string, int> = {}
    ages["ana"] = 31
    ages["bob"] = 27
    ages["léo"] = 19
    ages["ana"] += 1
    ages["bob"] -= 7
    print(ages, ages.len(), ages.has("ana"), ages.has("zoe"), ages["ana"])
    print(ages.get("bob") or 0, ages.get("zoe") or -1, ages.keys(), ages.values())
    ages.remove("bob")
    ages.remove("nobody")
    ages["zoe"] = 40
    print(ages, ages.len(), ages.keys().join(","))
    for name in ages {
        print("{name} is {ages[name]}")
    }

    // int and bool keys, literals
    var squares = {1: 1, 2: 4, 3: 9, -4: 16}
    var total = 0
    for k in squares {
        total += squares[k] * k
    }
    print(squares, total, squares.has(-4), squares.has(4), squares[3])
    var flags = {true: "yes", false: "no"}
    print(flags, flags[true], flags[1 > 2], flags.len())
    var names: map<int, string> = {10: "ten", 20: "twenty"}
    names[30] = "thirty"
    names[10] += "!"
    names[20] = names[20] + names[10]
    print(names, describe(names), names.values().sort())

    // values that are lists, structs and maps
    var groups: map<string, [int]> = {"even": [], "odd": []}
    for i in 0..7 {
        if i % 2 == 0 {
            groups["even"].push(i)
        } else {
            groups["odd"].push(i * 10)
        }
    }
    groups["odd"][1] += 5
    print(groups, groups["even"].len(), groups["odd"][1])
    var stock = {"pen": Stock{name: "pen", count: 3}}
    stock["ink"] = Stock{name: "ink", count: 0}
    stock["pen"].count += 4
    stock["ink"] = Stock{name: "blue ink", count: 2}
    print(stock, stock["pen"].count, stock["ink"].name)
    var nested = {"a": {"x": 1}, "b": {"y": 2, "z": 3}}
    nested["a"]["w"] = 9
    print(nested, nested["b"]["z"], nested["a"].len())

    // growing far past the first size, then shrinking
    var big: map<int, int> = {}
    for i in 0..5000 {
        big[i * 7] = i
    }
    var sum = 0
    for k in big {
        sum += big[k] - k
    }
    print(big.len(), sum, big[7 * 4999], big.has(7 * 5000), big.get(35) or -1)
    for i in 0..5000 {
        if i % 3 != 0 {
            big.remove(i * 7)
        }
    }
    print(big.len(), big.has(0), big.has(7), big.has(21), big.keys().slice(0, 5))
    for i in 0..300 {
        big[-i - 1] = i
    }
    print(big.len(), big[-300], big.keys().slice(1665, 1670))
    big.clear()
    big[5] = 5
    print(big, big.len())

    var words = tally(["the", "cat", "and", "the", "hat", "and", "the", "bat"])
    print(words, words["the"], words.keys().sort())
    var long_keys: map<string, int> = {}
    for i in 0..200 {
        long_keys["a rather long key number {i} that goes past eight bytes"] = i
        long_keys["k{i}"] = -i
    }
    print(long_keys.len(), long_keys["a rather long key number 77 that goes past eight bytes"], long_keys["k199"], long_keys.has("k200"))

    // equality does not depend on the order, printing does
    var one = {"a": 1, "b": 2}
    var two = {"b": 2, "a": 1}
    var three = {"a": 1, "b": 3}
    print(one == two, one != two, one == three, one, two, {"k": [1]} == {"k": [1]})

    // errors
    var prices = {"tea": 3, "cake": 5}
    print(lookup(prices, "tea") or -1, lookup(prices, "wine") or -1)
    prices.get("wine") catch err {
        print(err)
    }
}
