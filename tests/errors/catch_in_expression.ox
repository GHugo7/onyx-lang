// error: E0205
fn main() {
    print(1 + (parse_int("x") catch err { 0 }))
}
