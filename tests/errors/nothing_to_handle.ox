// error: E0202
fn one() -> int {
    return 1
}

fn main() {
    print(one() or 0)
}
