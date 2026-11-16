// error: E0109
enum Color {
    Red
    Green(int)
}

fn f(c: Color) -> int {
    match c {
        Red {
            return 1
        }
        Green(n) {
            print(n)
        }
    }
}

fn main() {
    print(f(Color.Red))
}
