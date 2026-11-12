// Building a long string piece by piece, then comparing strings.
fn main() {
    var text = ""
    for i in 0..20000 {
        text += "item {i}, "
    }
    print(text.len())

    var matches = 0
    for i in 0..300000 {
        var a = "key{i % 100}"
        var b = "key{i % 7}"
        if a == b {
            matches += 1
        }
    }
    print(matches)
}
