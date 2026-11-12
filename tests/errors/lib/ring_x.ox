import "ring_y"

var counter = 100
var first = ring_y.next()

fn bump() -> int {
    counter += 1
    return counter
}
