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

A hello-world executable is about 9 KB.

## Status: experimental

The native target is being built up step by step. It currently supports:

- `int` (a real 64-bit integer), `bool`, `string`
- structs with methods, interfaces, struct equality
- lists: literals, indexing, `for ... in`, and the methods `len`, `push`,
  `insert`, `remove`, `clear`, `contains`, `index_of`, `slice`, `reverse`,
  `sort`, `join`
- functions, recursion, any number of parameters
- top-level `var` and `const`
- `var`, assignment, `if` / `else`, `while`, `for i in a..b`, `break`,
  `continue`, `return`
- arithmetic, comparisons, `&&`, `||`, `!`
- string interpolation, `+`, comparisons and `.len()`
- `print`, `str`, `abs`, `min`, `max`, `exit`, `panic`
- modules (`import`)

Anything else (floats, maps, lambdas, error handling, `fork`, channels, the
other string methods, `map` / `filter` / `sort_by`) is rejected with error
`E0500` rather than compiled incorrectly. Those programs still run on the
default JavaScript target.

Known gaps in what is supported:

- Infinite recursion ends with `killed by signal 11` instead of a clean
  message.
- The generated code is not optimized. Arithmetic and calls are fast, but
  programs that create many objects are currently slower than on the
  JavaScript target.
- Only Linux on x86-64 is supported.

## Memory

There is no garbage collector. Every string, list and struct carries a
reference count: the number of variables, fields and list slots that point to
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

Freed memory is reused immediately: a loop that creates 90 million short-lived
objects runs in about 50 KB of memory.

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

## How it works

The pipeline is the same as for JavaScript up to the type checker; only the
last stage differs.

| File | Role |
| --- | --- |
| `src/native/mod.rs` | Walks the checked program and emits machine code |
| `src/native/asm.rs` | Encodes x86-64 instructions and resolves labels |
| `src/native/elf.rs` | Wraps the code in an ELF executable |
| `src/native/runtime.ox` | The runtime, **written in Onyx** |

The generated code is a simple stack machine: an expression leaves its value
in `rax`, intermediate values are pushed on the stack, local variables live in
the function's frame. It is not optimized yet.

The runtime (the memory allocator, reference counting, strings, lists,
printing, equality) is ordinary Onyx code compiled along with every program.
It relies on a few low-level operations that only it may use: reading and
writing memory (`__load8`, `__store64`, ...) and calling the kernel
(`__syscall`). The layout of objects in memory is documented at the top of
`runtime.ox`.

## Roadmap for this target

1. Maps and the remaining string and list methods
2. Floats
3. Error handling (`!`, `?`, `or`, `catch`)
4. Lambdas and closures
5. Files, arguments, `input`
6. `fork` and channels
7. Weak references, to break cycles
8. Other systems (ARM64, Windows, macOS)
