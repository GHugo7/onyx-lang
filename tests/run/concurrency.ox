struct Worker {
    id: int

    fn run(self, jobs: chan<int>, results: chan<string>) {
        for job in jobs {
            sleep(1)
            results <- "worker {self.id} did job {job}"
        }
    }
}

fn produce(n: int, out: chan<int>) {
    for i in 0..n {
        out <- i * i
    }
    out.close()
}

fn slow_double(n: int) -> int {
    sleep(5)
    return n * 2
}

fn slow_or_fail(n: int) -> int! {
    sleep(1)
    if n > 2 { fail "too big" }
    return n
}

fn main() {
    // unbuffered channel + close + for-in
    let squares = chan<int>()
    fork { produce(5, squares) }
    let got: [int] = []
    for v in squares {
        got.push(v)
    }
    print(got)

    // buffered channel: sends do not block until full
    let buf = chan<string>(2)
    buf <- "a"
    buf <- "b"
    print(<-buf, <-buf)

    // fan-out to workers
    let jobs = chan<int>()
    let results = chan<string>()
    for id in 1..3 {
        let w = Worker{id: id}
        fork { w.run(jobs, results) }
    }
    fork {
        for j in 0..4 {
            jobs <- j
        }
        jobs.close()
    }
    let lines: [string] = []
    for i in 0..4 {
        lines.push(<-results)
    }
    print(lines.len(), "results")

    // parallel tasks finish together
    let start = now()
    let done = chan<int>()
    for i in 1..6 {
        fork { done <- slow_double(i) }
    }
    let sum = 0
    for i in 0..5 {
        sum += <-done
    }
    print("sum", sum, "parallel:", now() - start < 20)

    // async calls inside expressions, `or`, and callbacks
    print(slow_double(2) + slow_double(3))
    print(slow_or_fail(1) or -1, slow_or_fail(5) or -1)
    let v = slow_or_fail(9) catch e {
        print("caught:", e)
        0
    }
    print(v)
    print([1, 2, 3].map(fn(x: int) -> int { return slow_double(x) }))

    // closures share variables with forks
    let counter = 0
    let finished = chan<bool>()
    for i in 0..10 {
        fork {
            counter += 1
            finished <- true
        }
    }
    for i in 0..10 { <-finished }
    print("counter", counter)
}
