// Strings on the native target: every length around the fast paths of the
// runtime (copies of 0-3, 4-7, 8-16 and more bytes; lengths and comparisons
// done eight bytes at a time), growth in place, and number formatting.

struct Tag {
    name: string
    weight: int
}

fn repeat(piece: string, times: int) -> string {
    var out = ""
    for i in 0..times {
        out += piece
    }
    return out
}

fn show(n: int) -> string {
    return "<{n}>"
}

fn main() {
    // concatenation of every pair of lengths from 0 to 20
    var checksum = 0
    for a in 0..21 {
        for b in 0..21 {
            var left = repeat("x", a)
            var right = repeat("yz", b)
            var both = left + right
            var built = "{left}{right}"
            if both != built || both.len() != a + 2 * b {
                print("mismatch", a, b)
            }
            checksum += both.len() * (a + 1)
        }
    }
    print("concat checksum", checksum)
    print(repeat("ab", 0) + "|", repeat("ab", 1) + "|", repeat("ab", 4) + "|", repeat("abc", 9) + "|")

    // lengths count characters, not bytes
    var accents = ["", "é", "aé", "éa", "abcdefgé", "abcdefghé", "éabcdefgh", "abcdefghijklmnoé", "€uro", "naïve café"]
    for word in accents {
        print(word, word.len(), (word + word).len(), "{word}!".len())
    }
    for n in 0..20 {
        var plain = repeat("a", n)
        var mixed = repeat("a", n) + "é" + repeat("b", n)
        if plain.len() != n || mixed.len() != 2 * n + 1 {
            print("wrong length", n)
        }
    }

    // comparisons: equal for a while, then different
    var base = "0123456789abcdefghijklmnopqrstuvwxyz"
    for cut in [0, 1, 7, 8, 9, 15, 16, 17, 23, 24, 25, 35] {
        var same = repeat("0123456789abcdefghijklmnopqrstuvwxyz", 1)
        var shorter = repeat("q", 0)
        var k = 0
        for c in ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o", "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z"] {
            if k < cut {
                shorter += c
            }
            k += 1
        }
        var bigger = shorter + "~"
        var smaller = shorter + " "
        print(cut, base == same, base == shorter, shorter < base || cut == 36, bigger > base, smaller < base || cut == 0, shorter == shorter + "", bigger != smaller)
    }
    print("a" < "b", "b" < "a", "abc" < "abd", "abc" < "ab", "" < "a", "a" <= "a", "é" > "z", "Z" < "a")

    // growth in place must not disturb other variables holding the old text
    var s = "start"
    var before = s
    s += "+more"
    var copy = s
    s = s + "+again"
    print(before, copy, s)
    var doubled = "ab"
    doubled += doubled
    doubled = doubled + doubled
    print(doubled, doubled.len())
    var long = ""
    for i in 0..5000 {
        long += "item {i}, "
    }
    var snapshot = long
    long += "end"
    print(long.len(), snapshot.len(), long == snapshot, long != snapshot)

    // numbers as text, around every change of length
    var numbers = [0, 1, 9, 10, 11, 99, 100, 101, 999, 1000, 1001, 9999, 10000, 99999, 100000, 999999, 1000000, 9999999, 10000000, 123456789, 1000000007, 987654321012, 9007199254740991]
    for n in numbers {
        print(n, -n, "{n}", "[{-n}]", str(n).len(), show(n), show(-n) + str(n))
    }
    print([0, -1, 10, -10, 100, -100], [7].join(","), [1, 22, 333].join(" + "), "{[1, 2]} {[-3]}")

    // many pieces of every type in one string
    var tag = Tag{name: "t", weight: 3}
    var flags = [true, false]
    print("{1}{"two"}{3 > 2}{[4, 5]}{tag}{tag.name}{tag.weight}{flags[1]}{"é"}{-6}")
    print("{tag.name}{tag.name}{tag.weight + 1} {"{tag.name}-{1 + 1}"} \{literal\} \"quoted\"")
    print(tag, [tag, Tag{name: "u \"v\"", weight: -1}], ["a\tb", "c\\d", "e\nf"])
}
