// String methods, indexing and loops over characters.

struct Word {
    text: string
    count: int
}

var g_title = "  The Quick  Brown Fox  "

fn initials(name: string) -> string {
    var out = ""
    for part in name.split(" ") {
        if part.len() > 0 {
            out += part[0].upper()
        }
    }
    return out
}

fn is_palindrome(text: string) -> bool {
    var letters = text.lower().replace(" ", "").chars()
    return letters == letters.reverse()
}

fn count_vowels(text: string) -> int {
    var n = 0
    for c in text {
        if "aeiouyéèà".contains(c.lower()) {
            n += 1
        }
    }
    return n
}

fn caesar(text: string, shift: int) -> string {
    var alphabet = "abcdefghijklmnopqrstuvwxyz"
    var out = ""
    for c in text {
        var at = alphabet.index_of(c)
        if at < 0 {
            out += c
        } else {
            out += alphabet[(at + shift) % 26]
        }
    }
    return out
}

fn frequencies(text: string) -> [Word] {
    var counts: map<string, int> = {}
    for word in text.lower().split(" ") {
        var clean = word.trim().replace(",", "").replace(".", "")
        if clean != "" {
            counts[clean] = (counts.get(clean) or 0) + 1
        }
    }
    var out: [Word] = []
    for key in counts.keys().sort() {
        out.push(Word{text: key, count: counts[key]})
    }
    return out
}

fn main() {
    // length and indexing count characters, not bytes
    var word = "héllo wörld"
    print(word.len(), word[0], word[1], word[4], word[7], word[10], "日本語".len(), "日本語"[1], "".len())
    print("a"[0] == "a", word[1] == "é", word[1] + word[7])

    // case
    print("Hello, World!".upper(), "Hello, World!".lower(), "".upper(), "123 abc XYZ".upper())
    print("été à Noël, où ça ? çÇ œŒ ÿŸ".upper(), "ÉTÉ À NOËL, OÙ ÇA ? çÇ œŒ ÿŸ".lower())
    print("straße".upper(), "ΑΒΓ αβγ".lower(), "αβγ άέή".upper(), "Привет Мир".upper(), "Привет Мир".lower())
    print("日本語 abc".upper(), "ǅ stays".lower().len())

    // trim
    print("[" + g_title.trim() + "]", "[" + "\t\n x y \r\n".trim() + "]", "[" + "   ".trim() + "]", "[" + "".trim() + "]", "[" + "none".trim() + "]")
    print("[" + "  é  ".trim() + "]", "[" + " é".trim() + "]", "[" + "é ".trim() + "]", " x ".len())

    // searching
    print("banana".contains("nan"), "banana".contains("nab"), "banana".contains(""), "".contains(""), "".contains("a"), "ab".contains("abc"))
    print("banana".starts_with("ban"), "banana".starts_with("an"), "banana".starts_with(""), "banana".starts_with("bananas"))
    print("banana".ends_with("ana"), "banana".ends_with("an"), "banana".ends_with(""), "banana".ends_with("xbanana"))
    print("banana".index_of("an"), "banana".index_of("x"), "banana".index_of(""), "banana".index_of("banana"), "banana".index_of("a"))
    print("crème brûlée".index_of("brûlée"), "crème brûlée".index_of("e"), "日本語".index_of("語"), "aaaab".index_of("aab"))

    // slices
    var text = "hello, world"
    print(text.slice(0, 5), text.slice(7, 12), text.slice(7, 100), text.slice(-5, -1), text.slice(3, 3), text.slice(5, 2), text.slice(-100, 2), "[" + text.slice(50, 60) + "]")
    print(word.slice(1, 4), word.slice(6, 11), word.slice(-5, 100), "日本語".slice(1, 3), "日本語".slice(0, 1), word.slice(0, 11) == word, "".slice(0, 0) == "")

    // replace
    print("banana".replace("an", "AN"), "banana".replace("a", ""), "banana".replace("x", "y"), "banana".replace("banana", ""), "aaa".replace("aa", "b"))
    print("abc".replace("", "-"), "".replace("", "-"), "héé".replace("", "."), "héé".replace("é", "ee"), "a$b".replace("$", "$$"), "x".replace("x", "$&$&"))
    print("one two  three".replace(" ", "_"), "tick tick tick".replace("tick", "tock"))

    // split and chars
    print("a,b,c".split(","), "a,,b,".split(","), "".split(","), "abc".split(""), "".split(""), "a".split("a"), "no separator".split("|"))
    print("one, two, three".split(", "), "aXXbXXc".split("XX"), "aXXXb".split("XX"), "héllo".split(""), "héllo".split("l"))
    print("héllo".chars(), "".chars(), "日本語".chars().len(), "a b".chars().join("|"), "x".chars())

    // repeat
    print("ab".repeat(3), "ab".repeat(0), "ab".repeat(1), "".repeat(5), "é".repeat(4), "-".repeat(20).len())

    // loops over characters
    var seen = ""
    for c in "héllo 日本" {
        seen += "<" + c + ">"
    }
    print(seen)
    for c in "" {
        print("never", c)
    }
    var first_upper = ""
    for c in "find The first" {
        if c == " " {
            continue
        }
        if c.upper() == c {
            first_upper = c
            break
        }
    }
    print(first_upper, count_vowels("Bonjour à tous, été comme hiver"))
    for c in "ab" {
        for d in "xyz".chars() {
            seen = c + d
        }
        print(seen)
    }

    // small programs
    print(initials("ada lovelace"), initials("  grace   brewster hopper "), initials(""))
    print(is_palindrome("A man a plan a canal Panama"), is_palindrome("not one"), is_palindrome(""))
    print(caesar("hello, world", 3), caesar(caesar("round trip", 5), 21))
    for w in frequencies("The cat and the hat. The end, and the start.") {
        print(w.text, w.count)
    }
    var csv = "name,age\nAda,36\nGrace,45"
    var total = 0
    for line in csv.split("\n").slice(1, 10) {
        var cells = line.split(",")
        total += parse_int(cells[1]) or 0
        print(cells[0].upper() + " is " + cells[1])
    }
    print(total, g_title.trim().lower().split("  "), g_title.trim().split(" ").len())

    // comparisons still work on the results
    print("b".repeat(2) > "a".repeat(3), "abc".slice(0, 2) == "ab", "ABC".lower() == "abc", "a,b".split(",") == ["a", "b"])
}
