// A million insertions and two million lookups in maps, with integer and
// string keys, then a walk over every entry.

fn main() {
    var squares: map<int, int> = {}
    for i in 0..500000 {
        squares[i * 7 % 1000003] = i
    }
    var found = 0
    for i in 0..1000000 {
        if squares.has(i) {
            found += squares[i] % 3
        }
    }

    var words: map<string, int> = {}
    for i in 0..500000 {
        var word = "w{i % 50000}"
        words[word] = (words.get(word) or 0) + 1
    }
    var total = 0
    for word in words {
        total += words[word] + word.len()
    }
    for i in 0..300000 {
        squares.remove(i)
    }
    print(found, words.len(), total, squares.len())
}
