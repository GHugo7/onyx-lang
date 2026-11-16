// error: E0102
enum Color {
    Red
    Green(int)
}

fn main() {
    match Color.Red {
        1 {
        }
        else {
        }
    }
}
