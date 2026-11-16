// error: E0106
enum Color {
    Red
    Green(int)
}

fn main() {
    print(Color.Blue)
}
