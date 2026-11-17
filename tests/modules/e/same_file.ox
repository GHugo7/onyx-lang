import "./bad/../bad/lib" as l1
import "bad/lib" as l2

fn main() {
    l1.ok()
    l2.ok()
}
