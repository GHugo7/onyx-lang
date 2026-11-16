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
    var c0 = chan<int>(2)
    fork {
        send_two(c0, 16)
        fork {
            pass_on(c0, c0)
            print("T0x len", c0 == c0)
            print("T0x half", got_half(c0) or -1)
        }
    }
    fork {
        c0 <- 48
    }
    fork {
        print("T2 got", <-c0)
    }
    fork {
        fork {
            c0 <- 3
            pass_on(c0, c0)
            send_two(c0, 25)
        }
        print("T3 get", get(c0))
        print("T3 half", got_half(c0) or -1)
        c0 <- 31
        print("T3 map", [1, 2].map(twice), [3].map(fn(n: int) -> int {
            return n + <-c0
        }))
    }
    print("M got", <-c0)
    print("M half", got_half(c0) or -1)
    print("M.2")
    sleep(3)
    c0 <- 14
    sleep(6)
    c0.close()
    print("main done")
}
