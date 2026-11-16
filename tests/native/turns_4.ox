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
        print("T0.0")
        send_two(c0, 4)
        fork {
            send_two(c0, 44)
        }
    }
    fork {
        print("T1 get", get(c0))
        c0 <- 17
    }
    fork {
        print("T2.0")
        print("T2 half", got_half(c0) or -1)
        print("T2.2")
        print("T2 half", got_half(c0) or -1)
    }
    fork {
        print("Mx get", get(c0))
        print("Mx got", <-c0)
        c0 <- 23
    }
    print("M half", got_half(c0) or -1)
    c0.close()
    print("main done")
}
