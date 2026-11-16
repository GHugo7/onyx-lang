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
| `alloc` | 9 million short-lived objects | 176 ms | 170 ms | 8.2 KB |
| `closures` | 3 million calls through function values; `map`, `filter`, `sort_by` | 26 ms | 380 ms | 12.3 KB |
| `collatz` | branches, division, multiplication | 360 ms | 1465 ms | 5.5 KB |
| `fib` | 39 million recursive calls | 285 ms | 438 ms | 5.3 KB |
| `loops` | nested loops, `%` by a constant | 206 ms | 328 ms | 5.4 KB |
| `maps` | a million insertions, two million lookups | 196 ms | 381 ms | 17.4 KB |
| `nbody` | float arithmetic and square roots | 17 ms | 53 ms | 14.9 KB |
| `print` | 500 000 lines of output | 23 ms | 493 ms | 5.4 KB |
| `shapes` | 5 million calls through an interface | 22 ms | 413 ms | 7.5 KB |
| `sieve` | list reads and writes | 116 ms | 306 ms | 8.1 KB |
| `sort` | sorting a million integers | 160 ms | 460 ms | 9.6 KB |
| `strings` | building a long string, comparing | 13 ms | 43 ms | 7.8 KB |
| `tasks` | 200 000 messages through a chain of 100 tasks | 12 ms | 78 ms | 11.8 KB |
| `structs` | 5 million method calls on structs | 15 ms | 44 ms | 7.3 KB |

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
- `shapes` and `closures` are slow on JavaScript because of how Onyx
  compiles calls through an interface or a function value there (each one
  is awaited), not because of Node.js itself.
- `alloc` is the one program where the two are level: the JavaScript
  engine can avoid creating objects that never leave a loop.
- `nbody` went from 105 ms to 17 ms when float variables moved into
  registers; most of that came from one instruction, the copy between two
  float registers, which had been making each result wait for an unrelated
  earlier one.

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

Executables went from about 20 KB to between 3 and 7 KB at the time; they
have grown by about 2 KB since, with the code that reports stack overflows
and looks after weak references. (The "after" column
is the measurement made at the time; the table above is more recent.)
