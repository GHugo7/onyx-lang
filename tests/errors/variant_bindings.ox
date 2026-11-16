// error: E0104
enum Color {
    Red
    Green(int)
}

fn main() {
    match Color.Green(1) {
        Green(a, b) {
            print(a)
        }
        else {
        }
    }
}
