// A chain of 100 tasks passing 2 000 numbers along, each adding one:
// 200 000 messages through unbuffered channels.

fn relay(from: chan<int>, to: chan<int>) {
    for v in from {
        to <- v + 1
    }
    to.close()
}

fn main() {
    var first = chan<int>()
    var last = first
    for i in 0..100 {
        var next = chan<int>()
        var from = last
        fork {
            relay(from, next)
        }
        last = next
    }
    fork {
        for i in 0..2000 {
            first <- i
        }
        first.close()
    }
    var sum = 0
    for v in last {
        sum += v
    }
    print(sum)
}
