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
        print("T0 half", got_half(c0) or -1)
    }
    fork {
        print("T1 got", <-c0)
        print("T1 get", get(c0))
    }
    fork {
        print("T2.0")
    }
    print("M.0")
    print("M len", c0 == c0)
    send_two(c0, 7)
    print("M.3")
    print("M.4")
    send_two(c0, 34)
    c0.close()
    print("main done")
}
