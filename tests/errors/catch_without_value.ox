// error: E0204
fn main() {
    let n = parse_int("x") catch err {
        print(err)
    }
    print(n)
}
