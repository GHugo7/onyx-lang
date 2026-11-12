// Sorting one million pseudo-random integers.
fn main() {
    var values: [int] = []
    var seed = 12345
    for i in 0..1000000 {
        seed = (seed * 1103515245 + 12345) % 2147483648
        values.push(seed % 1000000)
    }
    var sorted = values.sort()
    var checksum = 0
    for i in 0..1000 {
        checksum += sorted[i * 1000]
    }
    print(sorted[0], sorted[999999], checksum)
}
