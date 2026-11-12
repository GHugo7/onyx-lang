# Benchmarks

Small programs that each stress one thing. They only use what the native
target supports, so the same source runs on both targets.

```bash
cargo build --release
```

```bash
python3 benchmarks/run.py
```

The script builds every program for both targets and prints the best of three
runs, startup included.

## Results

Measured on a 4-core Intel Xeon at 2.1 GHz (Linux 6.18, Node.js 22). "Node"
is Node.js running the JavaScript that Onyx generates for the same source.
Numbers move by a few percent from run to run.

| Program | What it stresses | Native | Node | Native executable |
| --- | --- | ---: | ---: | ---: |
| `alloc` | 9 million short-lived objects | 153 ms | 177 ms | 5.9 KB |
| `collatz` | branches, division, multiplication | 372 ms | 1583 ms | 3.6 KB |
| `fib` | 39 million recursive calls | 296 ms | 385 ms | 3.4 KB |
| `loops` | nested loops, `%` by a constant | 198 ms | 330 ms | 3.5 KB |
| `maps` | a million insertions, two million lookups | 223 ms | 434 ms | 11.2 KB |
| `print` | 500 000 lines of output | 19 ms | 533 ms | 3.4 KB |
| `shapes` | 5 million calls through an interface | 22 ms | 474 ms | 5.6 KB |
| `sieve` | list reads and writes | 124 ms | 312 ms | 5.8 KB |
| `sort` | sorting a million integers | 173 ms | 659 ms | 7.6 KB |
| `strings` | building a long string, comparing | 18 ms | 64 ms | 6.1 KB |
| `structs` | 5 million method calls on structs | 19 ms | 60 ms | 5.4 KB |

Peak memory of the same runs:

| Program | Native | Node |
| --- | ---: | ---: |
| `alloc` | 32 KB | 66 MB |
| `fib` | 20 KB | 48 MB |
| `maps` | 23 MB | 115 MB |
| `sieve` | 65 MB | 204 MB |
| `sort` | 23 MB | 137 MB |
| `strings` | 264 KB | 54 MB |
| `structs` | 80 KB | 51 MB |

Things to keep in mind when reading these:

- Node.js spends about 40 ms starting up; that is part of its numbers.
- `shapes` is slow on JavaScript because of how Onyx compiles calls through
  an interface there (each one is awaited), not because of Node.js itself.
- `alloc` is the closest of them: the JavaScript engine can avoid creating
  objects that never leave a loop.

## History

The same programs, native target, before and after the optimisation work
described in [`docs/native.md`](../docs/native.md):

| Program | Before | After |
| --- | ---: | ---: |
| `alloc` | 854 ms | 144 ms |
| `collatz` | 1171 ms | 390 ms |
| `fib` | 330 ms | 290 ms |
| `loops` | 640 ms | 237 ms |
| `print` | 334 ms | 18 ms |
| `shapes` | 62 ms | 25 ms |
| `sieve` | 391 ms | 103 ms |
| `sort` | 284 ms | 172 ms |
| `strings` | 5280 ms | 16 ms |
| `structs` | 57 ms | 15 ms |

Executables went from about 20 KB to between 3 and 7 KB. (The "after" column
is the measurement made at the time; the table above is more recent.)
