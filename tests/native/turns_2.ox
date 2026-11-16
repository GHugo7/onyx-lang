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
    var c0 = chan<int>(0)
    fork {
        c0 <- 22
        print("T0.1")
        print("T0 len", c0 == c0)
    }
    fork {
        print("T1.0")
        print("T1 got", <-c0)
        c0 <- 20
    }
    fork {
        print("T2 half", got_half(c0) or -1)
        print("T2.1")
        print("T2.2")
    }
    fork {
        fork {
            sleep(6)
            send_two(c0, 14)
            send_two(c0, 42)
        }
        print("T3 get", get(c0))
    }
    print("M half", got_half(c0) or -1)
    print("M half", got_half(c0) or -1)
    print("M.2")
    fork {
        sleep(6)
    }
    print("M.4")
    print("M got", <-c0)
    print("main done")
}
