// Tasks taking turns: a generated program (see docs/native.md, "Tasks").

fn pass_on(a: chan<int>, b: chan<int>) {
    b <- <-a + 1
}

fn twice(n: int) -> int {
    return n * 2
}

fn send_two(c: chan<int>, v: int) {
    c <- v
    c <- v + 1
}

fn get(c: chan<int>) -> int {
    return <-c
}

fn half(n: int) -> int! {
    if n % 2 != 0 {
        fail "odd"
    }
    return n / 2
}

fn got_half(c: chan<int>) -> int! {
    return half(<-c)?
}

fn main() {
    var c0 = chan<int>(1)
    fork {
        fork {
            print("T0x len", c0 == c0)
            c0 <- 21
            pass_on(c0, c0)
        }
        pass_on(c0, c0)
        print("T0 got", <-c0)
        print("T0.3")
        print("T0.4")
    }
    print("M.0")
    fork {
        print("Mx map", [1, 2].map(twice), [3].map(fn(n: int) -> int {
            return n + <-c0
        }))
        c0 <- 32
        print("Mx.2")
    }
    c0 <- 27
    print("main done")
}
