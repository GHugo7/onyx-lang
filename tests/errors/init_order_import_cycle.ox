// error: E0118
// ring_x and ring_y import each other, and ring_y needs a variable of ring_x
// before ring_x had the chance to initialise it.
import "lib/ring_x"

fn main() {
    print(ring_x.first)
}
