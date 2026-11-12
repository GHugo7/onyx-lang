// Nested loops and integer arithmetic.
fn main() {
    var sum = 0
    for i in 0..20000 {
        for j in 0..10000 {
            sum += (i * j + 7) % 13
        }
    }
    print(sum)
}
