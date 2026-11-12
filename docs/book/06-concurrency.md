# 6. Concurrency

## fork

`fork { ... }` starts the block as a separate task and continues immediately.

```onyx
fn main() {
    fork {
        sleep(50)
        print("second")
    }
    print("first")
    sleep(100)
}
```

## Channels

Tasks communicate through channels. `ch <- value` sends, `<-ch` receives, and
each side waits for the other.

```onyx
fn download(name: string, done: chan<string>) {
    sleep(100)                  // pretend this takes a while
    done <- "{name} downloaded"
}

fn main() {
    let done = chan<string>()
    let files = ["a.zip", "b.zip", "c.zip"]
    for f in files {
        fork { download(f, done) }      // all three run at once
    }
    for f in files {
        print(<-done)                   // about 100 ms in total, not 300
    }
}
```

`chan<T>(n)` creates a buffered channel: up to `n` sends succeed without a
receiver waiting.

## Closing and looping

A sender can `close()` a channel to say that nothing more will come.
`for ... in` on a channel reads until then.

```onyx
fn count_to(n: int, out: chan<int>) {
    for i in 1..n + 1 {
        out <- i
    }
    out.close()
}

fn main() {
    let numbers = chan<int>()
    fork { count_to(5, numbers) }
    let sum = 0
    for n in numbers {
        sum += n
    }
    print(sum)    // 15
}
```

## Good to know

- A `fork` block cannot `return` from the function around it, and has no
  caller for `?`; handle errors inside it with `or` or `catch`.
- If the program ends up waiting on a channel nobody will ever send to, it
  stops with a `deadlock` message instead of hanging.
- On the JavaScript target, tasks take turns on one thread. They overlap while
  waiting (`sleep`, `fetch`, channels), which is what matters for I/O. Heavy
  computations do not run in parallel yet; the JVM target will use real
  threads.

Next: [Testing](07-testing.md)
