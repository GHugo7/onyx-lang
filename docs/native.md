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
- functions, recursion, any number of parameters
- `var`, assignment, `if` / `else`, `while`, `for i in a..b`, `break`,
  `continue`, `return`
- arithmetic, comparisons, `&&`, `||`, `!`
- string interpolation, `+`, comparisons and `.len()`
- `print`, `str`, `abs`, `min`, `max`, `exit`, `panic`
- modules (`import`)

Anything else (floats, structs, lists, maps, lambdas, error handling, `fork`,
channels, top-level variables) is rejected with error `E0500` rather than
compiled incorrectly. Those programs still run on the default JavaScript
target.

Known gaps in what is supported:

- Memory is allocated but never released yet. Reference counting comes with
  structs and lists.
- Infinite recursion ends with `killed by signal 11` instead of a clean
  message.
- Only Linux on x86-64 is supported.

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

The runtime (memory allocation, string building, number formatting, output)
is ordinary Onyx code compiled along with every program. It relies on a few
low-level operations that only it may use: reading and writing memory
(`__load8`, `__store64`, ...) and calling the kernel (`__syscall`).

## Roadmap for this target

1. Structs, lists and maps, with reference counting
2. Floats
3. Error handling (`!`, `?`, `or`, `catch`)
4. Lambdas and closures
5. Files, arguments, `input`
6. `fork` and channels
7. Other systems (ARM64, Windows, macOS)
