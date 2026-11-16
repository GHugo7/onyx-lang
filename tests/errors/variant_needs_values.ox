// error: E0104
enum Color {
    Red
    Green(int)
}

fn main() {
    print(Color.Green)
}
