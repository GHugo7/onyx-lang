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
        send_two(c0, 32)
        print("T0.1")
        print("T0 got", <-c0)
    }
    fork {
        c0 <- 47
        fork {
            print("T1x get", get(c0))
            print("T1x got", <-c0)
        }
    }
    fork {
        print("T2.0")
    }
    fork {
        print("T3 half", got_half(c0) or -1)
        print("T3.1")
        sleep(6)
        fork {
            print("T3x get", get(c0))
            print("T3x.1")
        }
        send_two(c0, 31)
    }
    c0 <- 10
    print("M half", got_half(c0) or -1)
    print("M.2")
    pass_on(c0, c0)
    c0.close()
    print("main done")
}
