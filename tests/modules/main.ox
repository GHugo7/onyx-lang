import "a/util"
import "b/util" as butil

interface Shaped {
    fn area(self) -> int
}

fn answer() -> int {
    return 42
}

fn take(p: util.Point, k: util.Kind) -> int {
    match k {
        util.Kind.One {
            return p.x
        }
        Two(q) {
            return q.y
        }
    }
}

fn main() {
    var p = util.make(1)
    var util2 = util.Point{x: 2, y: 3}
    var f = fn(util: int) -> int {
        return util + 1
    }
    print(take(p, util.Kind.Two(util2)), util.shared, butil.value(), f(1), answer())
    for util in [1, 2] {
        print(util)
    }
    var q: util.Point = util.make(5)
    var r = butil.value() catch err {
        0
    }
}

check "something" {
    expect(answer() == 42)
}
