# The native target

`--target native` makes the Onyx compiler write a Linux x86-64 executable by
itself: it encodes the processor instructions and the ELF file directly. No C
compiler, assembler, linker or Node.js is involved, and the result needs
nothing but the Linux kernel to run.

```bash
onyx run --target native hello.ox
```

```bash
onyx build --target native hello.ox
```

```bash
./build/hello
```

A hello-world executable is about 2.8 KB: only the functions a program
really uses, the runtime's included, end up in it.

## Status: experimental

The native target is being built up step by step. It currently supports:

- `int` (a real 64-bit integer), `bool`, `string`
- structs with methods, interfaces, struct equality
- lists: literals, indexing, `for ... in`, and the methods `len`, `push`,
  `pop`, `first`, `last`, `insert`, `remove`, `clear`, `contains`,
  `index_of`, `slice`, `reverse`, `sort`, `join`
- maps with `int`, `string` or `bool` keys: literals, `m[key]`,
  `m[key] = value`, `for key in m`, and the methods `len`, `get`, `has`,
  `remove`, `clear`, `keys`, `values`; they keep insertion order
- error handling: functions that return `T!`, `fail`, `?`, `or`, `catch`,
  the `error` type, and a `main` that can fail
- functions, recursion, any number of parameters
- top-level `var` and `const`
- `var`, assignment, `if` / `else`, `while`, `for i in a..b`, `break`,
  `continue`, `return`
- arithmetic, comparisons, `&&`, `||`, `!`
- strings: interpolation, `+`, `+=`, comparisons, `s[i]`, `for c in s`, and
  the methods `len`, `upper`, `lower`, `trim`, `contains`, `starts_with`,
  `ends_with`, `index_of`, `slice`, `replace`, `split`, `chars`, `repeat`
- `print`, `str`, `parse_int`, `abs`, `min`, `max`, `exit`, `panic`
- modules (`import`)

Anything else (floats, lambdas, `fork`, channels, `map` / `filter` /
`sort_by`, `onyx test`) is rejected with error
`E0500` rather than compiled incorrectly. Those programs still run on the
default JavaScript target. Functions that are never called are not compiled,
so an unsupported feature in unused code does not get in the way.

Known gaps in what is supported:

- Infinite recursion ends with `killed by signal 11` instead of a clean
  message. So does dropping a chain of objects nested hundreds of thousands
  deep (a hand-made linked list, say), because they are released recursively.
- Every list element takes 8 bytes, a `bool` included.
- `upper` and `lower` know the letters of the Latin alphabet with their
  accents, Greek and Cyrillic. Letters of other alphabets are left as they
  are, as are the few whose other case is longer (`İ`, `ŉ`, `ΐ`, `ΰ`), and a
  capital sigma always becomes `σ`.
- Positions in a string count characters, and a character takes one to four
  bytes: `s[i]` and `slice` have to walk from the start of the string when it
  holds accents or other non-ASCII characters. Use `for c in s` to go through
  a long text; it is a single pass.
- Adding or removing keys of a map inside a `for` loop over that same map
  is not specified: the two targets may visit different keys afterwards.
- Only Linux on x86-64 is supported.

## Memory

There is no garbage collector. Every string, list, map and struct carries a
reference count: the number of variables, fields and slots that point to
it. The compiler inserts the code that updates the count, and an object is
freed at the exact moment its count reaches zero. Nothing has to be written
in the program.

```onyx
struct Player {
    name: string
}

fn main() {
    var p = Player{name: "Kai"}    // count = 1
    var q = p                      // count = 2
    print(q.name)
}                                  // both variables go away: count = 0, freed
```

Freed memory is reused immediately: a loop that creates 9 million short-lived
objects peaks at 32 KB of memory.

Objects are compact. Each one starts with an 8-byte header (a 32-bit count and
the 32-bit address of its type's description); a struct with two fields takes
24 bytes, and blocks carry no hidden size field.

**The limit: cycles.** Two objects that point to each other keep each other
alive forever, because neither count can reach zero:

```onyx
struct Node {
    friends: [Node]
}

fn main() {
    var a = Node{friends: []}
    var b = Node{friends: []}
    a.friends.push(b)
    b.friends.push(a)    // a -> b -> a: never freed
}
```

A way to mark one of the links as weak is planned. Until then, avoid such
structures in long-running programs, or break the cycle by hand before
dropping it (`a.friends.clear()`).

To verify that a program frees everything, run it with the leak check:

```bash
onyx run --target native --leak-check main.ox
```

It exits with code 3 and a message if objects are still alive at the end.

## What the compiler does to make programs fast

Before code generation, for every target (`src/optimize.rs`):

- constant expressions are computed (`24 * 60 * 60` becomes `86400`);
- `const` values are copied into their uses;
- branches that cannot run and statements after a `return` are removed.

In the native code generator (`src/native/mod.rs`, `src/native/plan.rs`):

- **Variables in registers.** The six most used variables of each function
  live in processor registers; uses inside loops weigh more.
- **Direct operations.** `x + 1`, `i < n` or `total += price` work on the
  variable where it is. A condition is a comparison followed by a jump, not a
  boolean that is computed and then tested.
- **No division instruction for constants.** Dividing or taking the remainder
  by a constant is done with shifts or with one multiplication, which is
  several times faster. `x * 8` is a shift.
- **Borrowed arguments.** Passing a local variable to a function does not
  touch its reference count. Fields and list elements are read without
  counting when nothing can interfere.
- **Reference counting in place.** Retaining is two instructions; releasing
  only calls the runtime when the count reaches zero.
- **Strings that grow in place.** `s += piece` extends the string when no
  other variable holds it, so building a long text is linear, not quadratic.
  An interpolated string is assembled with a single allocation, and `print`
  writes its pieces without building the string at all.
- **Numbers without allocation.** The text of a number being printed or
  interpolated is written into a buffer on the stack.
- **Buffered output.** `print` fills a 64 KB buffer, written out when it is
  full, when the program ends, and after every line on a terminal.
- **Remembered method lookups.** A call through an interface remembers the
  last type it saw and the method it found.
- **Characters without allocation.** `for c in text`, `s[i]`, `chars` and
  `split("")` hand out the same 128 constant strings for ASCII characters;
  only accented and other multi-byte characters are allocated. Searching
  and counting skip eight ASCII bytes at a time.
- **Lists.** Reading an element is a bounds check and a load; `push` stores
  in place when the list has room.
- **Maps.** A hash table with open addressing over a dense array of entries:
  a lookup usually touches one slot and one entry, and walking a map is a
  walk over an array. Integer keys are hashed with one multiplication.
- **Errors without exceptions.** A function that can fail returns its value
  in one register and the error (or zero) in another, so `?` and `or` cost a
  test and a jump. Nothing is unwound and nothing is allocated when all
  goes well.

Measurements are in [`benchmarks/`](../benchmarks/README.md).

## How it works

The pipeline is the same as for JavaScript up to the type checker; only the
last stage differs.

| File | Role |
| --- | --- |
| `src/native/lower.rs` | Rewrites statements so that every `?` stands on its own |
| `src/native/mod.rs` | Walks the checked program and emits machine code |
| `src/native/plan.rs` | Chooses the variables that live in registers |
| `src/native/asm.rs` | Encodes x86-64 instructions and resolves labels |
| `src/native/elf.rs` | Wraps the code in an ELF executable |
| `src/native/runtime.ox` | The runtime, **written in Onyx** |

An expression leaves its value in `rax`; `rcx`, `rdx` and `r8`-`r11` are
scratch. Arguments are pushed on the stack and the result comes back in
`rax`. A function that can fail also sets `rdx`: zero on success, otherwise
the error, which is simply its message string. `r15` holds the address of the runtime's state, which is followed by
the program's top-level variables. The conventions are described at the top
of `mod.rs`.

The runtime (the memory allocator, reference counting, strings, lists, maps,
printing, equality) is ordinary Onyx code compiled along with every program.
It relies on a few low-level operations that only it may use: reading and
writing memory (`__load8`, `__store64`, ...), copying bytes (`__copy`) and
calling the kernel (`__syscall`). The layout of objects in memory is
documented at the top of `runtime.ox`.

## How it is tested

- Every program in `tests/native` runs on both targets: the outputs must be
  identical, and the native run must release every object.
- `tests/fuzz.rs` generates random programs and holds them to the same
  standard, error handling and maps included. This is also how a bug in the
  JavaScript target was found (`?` under an `or` was caught by that `or`).
  `cargo test` tries a few dozen; `ONYX_FUZZ_SEEDS=5000 cargo test
  --release --test fuzz` searches harder.
- The instruction encoder is tested against the bytes that GNU `as`
  produces for the same instructions, and division by constants against
  real division over the whole 64-bit range.

## Roadmap for this target

1. Floats
2. Lambdas and closures, and with them `map`, `filter` and `sort_by`
3. Files, arguments, `input`
4. `fork` and channels
5. Weak references, to break cycles
6. Other systems (ARM64, Windows, macOS)
