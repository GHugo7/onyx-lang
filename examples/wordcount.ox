// Counts the most frequent words in a text file.
//
//     onyx run examples/wordcount.ox README.md

struct Entry {
    word: string
    count: int
}

fn count_words(text: string) -> map<string, int> {
    let counts: map<string, int> = {}
    let word = ""
    // A trailing space flushes the last word.
    for c in text.lower() + " " {
        if is_letter(c) {
            word += c
        } else if word.len() > 0 {
            counts[word] = (counts.get(word) or 0) + 1
            word = ""
        }
    }
    return counts
}

fn is_letter(c: string) -> bool {
    return (c >= "a" && c <= "z") || c == "'"
}

fn top(counts: map<string, int>, n: int) -> [Entry] {
    let entries: [Entry] = []
    for word in counts {
        entries.push(Entry{word: word, count: counts[word]})
    }
    let sorted = entries.sort_by(fn(e: Entry) -> int { return -e.count })
    return sorted.slice(0, min(n, sorted.len()))
}

fn main() -> void! {
    let path = args().first() catch err {
        fail "usage: onyx run wordcount.ox <file>"
    }
    let text = read_file(path)?
    let counts = count_words(text)
    print("{counts.len()} different words in {path}")
    for e in top(counts, 10) {
        print("{e.count}\t{e.word}")
    }
}

check "counts repeated words" {
    let counts = count_words("the cat and the hat")
    expect(counts["the"] == 2)
    expect(counts["cat"] == 1)
    expect(counts.len() == 4)
}

check "top is sorted by frequency" {
    let best = top(count_words("a b b c c c"), 2)
    expect(best.len() == 2)
    expect(best[0].word == "c")
    expect(best[1].word == "b")
}
