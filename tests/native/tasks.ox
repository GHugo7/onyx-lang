// fork, channels and the order in which tasks take turns.

struct Job {
    id: int
    payload: string
}

struct Counter {
    hits: int

    fn bump(self, by: int) {
        self.hits += by
    }
}

interface Shape {
    fn area(self) -> int
}

struct Square {
    side: int

    fn area(self) -> int {
        return self.side * self.side
    }
}

var g_log: [string] = []

fn note(text: string) {
    g_log.push(text)
}

fn produce(n: int, out: chan<int>) {
    for i in 1..n + 1 {
        out <- i * i
    }
    out.close()
}

fn worker(name: string, jobs: chan<Job>, results: chan<string>) {
    for job in jobs {
        results <- "{name} did {job.id}:{job.payload.upper()}"
    }
    results <- "{name} done"
}

fn relay(from: chan<int>, to: chan<int>, add: int) {
    for v in from {
        to <- v + add
    }
    to.close()
}

fn slow(label: string, ms: int, done: chan<string>) {
    sleep(ms)
    done <- label
}

fn half(n: int) -> int! {
    if n % 2 != 0 {
        fail "{n} is odd"
    }
    return n / 2
}

fn ask(question: chan<int>, answer: chan<string>) {
    for n in question {
        var result = half(n) catch err {
            answer <- "no: {err}"
            continue
        }
        answer <- "yes: {result}"
    }
    answer.close()
}

fn main() {
    // a task and an unbuffered channel
    var squares = chan<int>()
    fork {
        produce(5, squares)
    }
    var sum = 0
    for v in squares {
        sum += v
    }
    print(sum)

    // who runs first
    fork {
        note("child starts")
        sleep(1)
        note("child after sleep")
    }
    note("parent continues")
    sleep(5)
    note("parent after sleep")
    print(g_log)
    g_log.clear()

    // several workers on one queue
    var jobs = chan<Job>()
    var results = chan<string>()
    for name in ["a", "b", "c"] {
        fork {
            worker(name, jobs, results)
        }
    }
    fork {
        for i in 0..7 {
            jobs <- Job{id: i, payload: "p{i}"}
        }
        jobs.close()
    }
    var lines: [string] = []
    for i in 0..10 {
        lines.push(<-results)
    }
    for line in lines {
        print(line)
    }

    // buffered channels
    var box = chan<string>(2)
    box <- "one"
    box <- "two"
    fork {
        box <- "three"
        note("third sent")
        box <- "four"
        box.close()
    }
    note("before receiving")
    print(<-box, <-box)
    note("after two")
    for rest in box {
        note("got {rest}")
    }
    print(g_log)
    g_log.clear()

    // a pipeline of tasks
    var first = chan<int>()
    var second = chan<int>(1)
    var third = chan<int>()
    fork {
        relay(first, second, 100)
    }
    fork {
        relay(second, third, 1000)
    }
    fork {
        for i in 0..5 {
            first <- i
        }
        first.close()
    }
    var piped: [int] = []
    for v in third {
        piped.push(v)
    }
    print(piped)

    // sleeping tasks wake up in the order of their clocks
    var done = chan<string>()
    fork {
        slow("slowest", 60, done)
    }
    fork {
        slow("fast", 10, done)
    }
    fork {
        slow("middle", 35, done)
    }
    print(<-done, <-done, <-done)

    // variables shared between a task and the function that started it
    var total = 0
    var counter = Counter{hits: 0}
    var finished = chan<bool>()
    for i in 1..5 {
        fork {
            total += i
            counter.bump(i * 10)
            finished <- true
        }
    }
    for i in 1..5 {
        <-finished
    }
    print(total, counter.hits, counter)

    // errors handled inside a task
    var questions = chan<int>()
    var answers = chan<string>()
    fork {
        ask(questions, answers)
    }
    fork {
        for n in [4, 7, 10] {
            questions <- n
        }
        questions.close()
    }
    for a in answers {
        print(a)
    }

    // tasks that start tasks, closures and interfaces in tasks
    var shapes: [Shape] = [Square{side: 2}, Square{side: 3}]
    var areas = chan<int>(4)
    fork {
        for s in shapes {
            fork {
                areas <- s.area()
            }
        }
    }
    var twice = fn(n: int) -> int {
        return n * 2
    }
    print(twice(<-areas) + twice(<-areas), [1, 2, 3].map(twice), areas)

    // channels of channels, and a reply channel in a struct field
    var requests = chan<chan<string>>()
    fork {
        for reply in requests {
            reply <- "pong"
        }
    }
    var mine = chan<string>()
    requests <- mine
    print(<-mine)
    requests <- mine
    print(<-mine)
    requests.close()

    // interleaving of two talkative tasks
    var turn = chan<int>()
    fork {
        for i in 0..3 {
            note("A{i}")
            turn <- i
        }
    }
    fork {
        for i in 0..3 {
            note("B{i}")
            turn <- i + 10
        }
    }
    var seen: [int] = []
    for i in 0..6 {
        seen.push(<-turn)
        note("main{i}")
    }
    print(seen)
    print(g_log)

    // a task still running when main ends
    fork {
        sleep(20)
        print("last words")
    }
    print("main ends")
}
