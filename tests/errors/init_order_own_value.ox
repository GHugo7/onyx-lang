// error: E0118
var cache = build()

fn build() -> [int] {
    var out = [1]
    if out.len() > 5 {
        out = cache
    }
    return out
}

fn main() {
    print(cache)
}
