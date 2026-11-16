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

A hello-world executable is about 4.7 KB: only the functions a program
really uses, the runtime's included, end up in it.

## Status: experimental

The native target is being built up step by step. It currently supports:

- `int` (a real 64-bit integer), `float` (64 bits), `bool`, `string`
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
- weak references (`weak<T>`)
- lambdas and closures, functions as values (in variables, fields, lists,
  maps), and the list methods `map`, `filter` and `sort_by`
- top-level `var` and `const`
- `var`, assignment, `if` / `else`, `while`, `for i in a..b`, `break`,
  `continue`, `return`
- arithmetic, comparisons, `&&`, `||`, `!`
- floats: arithmetic and `%`, automatic conversion from `int`, `float`,
  `int`, `sqrt`, `pow`, `floor`, `ceil`, `round`, `abs`, `min`, `max`,
  `parse_float`, `random`, `random_int`
- strings: interpolation, `+`, `+=`, comparisons, `s[i]`, `for c in s`, and
  the methods `len`, `upper`, `lower`, `trim`, `contains`, `starts_with`,
  `ends_with`, `index_of`, `slice`, `replace`, `split`, `chars`, `repeat`
- `print`, `str`, `parse_int`, `abs`, `min`, `max`, `exit`, `panic`
- `fork`, channels (`chan<T>()`, `ch <- v`, `<-ch`, `close`, `for v in ch`)
- the outside world: `read_file`, `write_file`, `append_file`,
  `file_exists`, `args`, `env`, `input`, `now`, `sleep`
- modules (`import`)

The one thing left out is `fetch`, which is rejected with error
`E0500` rather than compiled incorrectly. Those programs still run on the
default JavaScript target. Functions that are never called are not compiled,
so an unsupported feature in unused code does not get in the way.

Known gaps in what is supported:

- Dropping a chain of objects nested hundreds of thousands deep (a
  hand-made linked list, say) runs out of stack, because they are released
  recursively; it is reported as a stack overflow.
- Every list element takes 8 bytes, a `bool` included.
- `upper` and `lower` know the letters of the Latin alphabet with their
  accents, Greek and Cyrillic. Letters of other alphabets are left as they
  are, as are the few whose other case is longer (`İ`, `ŉ`, `ΐ`, `ΰ`), and a
  capital sigma always becomes `σ`.
- Positions in a string count characters, and a character takes one to four
  bytes: `s[i]` and `slice` have to walk from the start of the string when it
  holds accents or other non-ASCII characters. Use `for c in s` to go through
  a long text; it is a single pass.
- `pow` can differ from the JavaScript target in the last digit (both are
  within one unit in the last place of the exact result). Every other float
  operation, and the text of floats, is identical.
- Converting a float that is not a number, or too big for an `int`, with
  `int`, `floor`, `ceil` or `round` gives an unspecified int.
- Tasks take turns on one thread, as on the JavaScript target: they overlap
  while they wait, not while they compute.
- When a task panics, the program stops at once. On the JavaScript target
  the other tasks may still print a line or two before it does.
- A task has a stack of 256 KB.
- A file is read as it is: bytes that are not valid UTF-8 are kept, where
  the JavaScript target replaces them.
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

A closure can be part of such a cycle too: a lambda stored in a variable
that it uses itself, or in a field of an object it captures, keeps itself
alive.

The way out is to make one of the links weak. A `weak<T>` points to an
object without counting as one of its references:

```onyx
struct Node {
    name: string
    parent: weak<Node>
    children: [Node]
}

fn main() {
    var root = Node{name: "root", parent: weak(), children: []}
    var child = Node{name: "child", parent: weak(root), children: []}
    root.children.push(child)        // root -> child, and child - - > root
    var up = child.parent.get() catch err {
        return
    }
    print(up.name)
}
```

`weak(object)` makes one, `weak()` makes an empty one, and `get()` gives the
object back, or fails with `the object is gone` if it has been freed. Here
the parents own their children and the children only look at their parent:
when `root` goes away, the whole tree is freed.

On the JavaScript target a garbage collector frees memory, cycles
included: there a weak reference simply holds its object, and `get` only
fails on an empty one. A program should not count on `get` failing.

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
- **Closures.** A lambda that captures nothing, like a named function used
  as a value, is a constant: making it allocates nothing. A captured
  variable is copied into the closure; only one that is assigned to after
  being captured moves into a shared box.
- **Floats.** The six most used float variables of a function live in SSE
  registers, like the integer ones live in general registers (their value
  is also kept in memory, from where the registers are filled again after a
  call). An expression such as `a * b + c * d` is computed there from start
  to end, and a float field of a struct is used where it is. Converting an int happens where the
  checker saw one used as a float, and a literal such as the 2 of `2 * x` is
  converted when the program is compiled.
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
| `src/native/widen.rs` | Makes conversions from `int` to `float` explicit |
| `src/native/capture.rs` | Finds what each lambda and `fork` block captures; boxes the variables they share |
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
printing, equality, the text of floats, `pow`) is ordinary Onyx code compiled along with every program.
It relies on a few low-level operations that only it may use: reading and
writing memory (`__load8`, `__store64`, ...), copying bytes (`__copy`) and
calling the kernel (`__syscall`). The layout of objects in memory is
documented at the top of `runtime.ox`.

## Closures

A function value is a small object, the closure: the address of the code,
followed by what the lambda captured from the functions around it. Calling
it passes the closure along, in a register, so that the code finds its
variables.

```onyx
fn counter() -> fn() -> int {
    var n = 0
    return fn() -> int {
        n += 1
        return n
    }
}
```

Here `n` outlives `counter` and is changed by the lambda, so it cannot stay
in `counter`'s stack frame, and cannot simply be copied either. The compiler
moves it into a box on the heap, which the function and the lambda both
point to; like everything else, the box is freed when the last of them goes
away. A captured variable that never changes afterwards is copied instead,
which costs nothing more.

## Talking to the system

Files, arguments, the environment, the keyboard and the clock are reached
with system calls of the Linux kernel, made by the runtime itself: `open`,
`read`, `write`, `close`, `access`, `clock_gettime`, `nanosleep`. There is
no C library in between. The arguments and the environment are read from
the stack, where the kernel puts them when a program starts. Input is read
4096 bytes at a time, so reading a large file line by line with `input`
stays fast.

## Tasks

`fork { ... }` starts a task: the block, compiled like a lambda, runs on a
stack of its own (256 KB, taken from the system when the task starts and
given back when it ends). All tasks share the one thread of the program and
take turns. Switching from one to another is saving seven registers and the
stack pointer, and loading those of the other: about twenty instructions,
with no call to the kernel.

A task runs until it has to wait: for a value on a channel, for room in
one, for `sleep`. It then stands in a line (of the channel, of the
sleepers) and the next task that is ready goes on. When nothing is ready,
the program sleeps until the first sleeper's time; when nothing ever will
be, it stops with the `deadlock` message.

The scheduler, the channels and the timers are written in Onyx in the
runtime (`runtime.ox`, "tasks" and "channels"). The order in which tasks
take turns is exactly the one of the JavaScript target, so that a program
prints the same thing on both: it was compared on hundreds of generated
programs.

A program without `fork` contains none of this, and pays nothing for it.

## Running out of stack

Recursion without end is stopped with `panic: stack overflow (infinite
recursion?)`, like on the JavaScript target. When the stack is full, the
next write lands on memory that the program may not touch and the kernel
sends it a signal; the runtime asked to be called in that case, on a small
stack kept aside. The stack of `main` is the usual 8 MB of Linux, which is
room for a recursion several hundred thousand calls deep; a task's stack
ends with a page that nothing may touch.

## Tests

`onyx test --target native` builds a program that calls every `check` block
in turn. A failed `expect` or a panic must abandon the check and let the
next one run, and there are no exceptions to do that with: before each
check, the place to come back to (the stack pointer and an address) is
noted, and a failure jumps straight back there.

## Floats as text

Writing a float in decimal and reading one back is done exactly, by the
runtime itself (`__rt_float_str` and `__rt_parse_float` in `runtime.ox`).
A float is shown with the fewest digits that read back as the same float,
so `0.1 + 0.2` is `0.30000000000000004` and `0.1` stays `0.1`; a string of
any length is read as the float nearest to the number it spells. Both need
numbers of more than 64 bits, which the runtime builds from 32-bit pieces.
They were compared with Node.js on tens of thousands of random floats.

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

1. `fetch`
2. Tasks on several threads
3. Other systems (ARM64, Windows, macOS)
