// Sieve of Eratosthenes: list reads and writes.
fn main() {
    var limit = 5000000
    var composite: [bool] = []
    for i in 0..limit + 1 {
        composite.push(false)
    }
    var count = 0
    for n in 2..limit + 1 {
        if !composite[n] {
            count += 1
            var multiple = n * n
            while multiple <= limit {
                composite[multiple] = true
                multiple += n
            }
        }
    }
    print(count)
}
