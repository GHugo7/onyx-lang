// error: E0119
enum Color {
    Red
    Green(int)
}

fn main() {
    var c = Color.Red
    match c {
        Red {
            print(1)
        }
    }
}
