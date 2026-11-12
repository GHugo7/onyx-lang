// error: E0204
fn main() {
    var n = parse_int("x") catch err {
        print(err)
    }
    print(n)
}
