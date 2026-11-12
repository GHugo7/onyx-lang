// error: E0109
fn f(n: int) -> int {
    if n > 0 {
        return 1
    }
}

fn main() {
    print(f(1))
}
