import "../a/util"

const WORDS = embed("../data/words.txt")
var notes = embed("../README.md")

fn main() {
    print(WORDS.len(), WORDS.split("\n"), notes.starts_with("# Module"))
    var embed = fn(s: string) -> string {
        return s + "!"
    }
    print(embed("local"), util.make(1))
}
