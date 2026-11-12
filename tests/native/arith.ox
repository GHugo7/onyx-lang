// Integer arithmetic on the native target, where operations with constants
// are compiled without multiplication or division instructions when possible.
// The values stay small enough for the JavaScript target to agree exactly.

fn report(label: string, values: [int]) {
    var sum = 0
    for v in values {
        sum = (sum * 31 + v) % 1000000007
    }
    print(label, sum)
}

fn main() {
    var inputs = [0, 1, -1, 2, -2, 3, -3, 7, -7, 8, -8, 9, 10, -10, 15, 16, 17, 99, 100, 101, -100, 127, 128, 129, 255, 256, 1000, -1000, 1023, 1024, 1025, 4095, 4096, 65535, 65536, 65537, 99999, 100000, 1000003, -1000003, 123456789, -123456789, 2147483647, -2147483648, 4294967296, -4294967297, 1099511627776, 281474976710655, -281474976710656]

    var q: [int] = []
    var r: [int] = []
    for x in inputs {
        q.push(x / 1)
        q.push(x / -1)
        q.push(x / 2)
        q.push(x / -2)
        q.push(x / 3)
        q.push(x / -3)
        q.push(x / 4)
        q.push(x / 5)
        q.push(x / 6)
        q.push(x / 7)
        q.push(x / -7)
        q.push(x / 8)
        q.push(x / -8)
        q.push(x / 9)
        q.push(x / 10)
        q.push(x / -10)
        q.push(x / 11)
        q.push(x / 12)
        q.push(x / 13)
        q.push(x / 16)
        q.push(x / 25)
        q.push(x / 60)
        q.push(x / 100)
        q.push(x / -100)
        q.push(x / 127)
        q.push(x / 128)
        q.push(x / 255)
        q.push(x / 256)
        q.push(x / 641)
        q.push(x / 1000)
        q.push(x / 1024)
        q.push(x / 4096)
        q.push(x / 65535)
        q.push(x / 65536)
        q.push(x / 99999)
        q.push(x / 1000003)
        q.push(x / 1048576)
        q.push(x / 2147483647)
        q.push(x / -2147483648)

        r.push(x % 1)
        r.push(x % -1)
        r.push(x % 2)
        r.push(x % -2)
        r.push(x % 3)
        r.push(x % -3)
        r.push(x % 4)
        r.push(x % 5)
        r.push(x % 6)
        r.push(x % 7)
        r.push(x % -7)
        r.push(x % 8)
        r.push(x % -8)
        r.push(x % 9)
        r.push(x % 10)
        r.push(x % -10)
        r.push(x % 11)
        r.push(x % 12)
        r.push(x % 13)
        r.push(x % 16)
        r.push(x % 25)
        r.push(x % 60)
        r.push(x % 100)
        r.push(x % -100)
        r.push(x % 127)
        r.push(x % 128)
        r.push(x % 255)
        r.push(x % 256)
        r.push(x % 641)
        r.push(x % 1000)
        r.push(x % 1024)
        r.push(x % 4096)
        r.push(x % 65535)
        r.push(x % 65536)
        r.push(x % 99999)
        r.push(x % 1000003)
        r.push(x % 1048576)
        r.push(x % 2147483647)
        r.push(x % -2147483648)
    }
    report("quotients", q)
    report("remainders", r)
    print(q.slice(0, 39))
    print(r.slice(39 * 6, 39 * 7))

    // the same divisors, known only when the program runs
    var divisors = [1, -1, 2, -2, 3, -3, 4, 5, 6, 7, -7, 8, -8, 9, 10, -10, 11, 12, 13, 16, 25, 60, 100, -100, 127, 128, 255, 256, 641, 1000, 1024, 4096, 65535, 65536, 99999, 1000003, 1048576, 2147483647, -2147483648]
    var q2: [int] = []
    var r2: [int] = []
    for x in inputs {
        for d in divisors {
            q2.push(x / d)
            r2.push(x % d)
        }
    }
    print("constant and variable divisors agree:", q == q2, r == r2)

    // multiplications by constants
    var m: [int] = []
    for x in [0, 1, -1, 3, -3, 1000, -1000, 123456, -123456, 1048576] {
        m.push(x * 0)
        m.push(x * 1)
        m.push(x * -1)
        m.push(x * 2)
        m.push(x * 3)
        m.push(x * 4)
        m.push(x * 8)
        m.push(x * 10)
        m.push(x * -16)
        m.push(x * 1000)
        m.push(x * 1024)
        m.push(x * 65536)
        m.push(2 * x)
        m.push(-7 * x)
        m.push(1024 * x + 1)
        m.push(x * x)
    }
    report("products", m)

    // constants on the left, variables on both sides, mixed
    var a = 37
    var b = -5
    print(100 - a, 100 / a, 100 % a, 7 - b, 7 / b, 7 % b, a - b, a / b, a % b, b / a, b % a, -a / 4, -a % 4)
    print(a + b * 3 - (a - b) / 2 % 7, (a * a - b * b) / (a + b), a * (b + 1) * (b - 1), 1 - (2 - (3 - (4 - a))))
    print(abs(b), abs(a), min(a, b), max(a, b), min(a, 12), max(b, -12), min(3, a), max(-9, b))

    // comparisons with constants and variables on either side
    print(a < 40, 40 < a, a <= 37, 37 <= a, a > b, b > a, a >= 37, 38 >= a, a == 37, 37 != a, b == -5, -5 == b)
    var count = 0
    for i in -20..20 {
        if i % 3 == 0 && i / 3 != -2 || i == 19 {
            count += i
        }
        if !(i < 5) && i <= 10 {
            count -= 1
        }
    }
    print(count)
}
