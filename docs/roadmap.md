# Roadmap

## v0.1: the core (done)

- Lexer, parser and type checker with rustc-style diagnostics
- Structs with methods, structural interfaces, lambdas and closures
- Lists, maps, strings, ranges
- Error handling with `!`, `?`, `or`, `catch`, `fail`
- `fork` and channels
- `check` blocks and `onyx test`
- Modules: `import "file"` with namespaced access and private names
- JavaScript backend; `onyx run` uses Node.js

## In progress: the native target

Onyx is moving towards being self-sufficient: the compiler writes executables
itself, without a C compiler or Node.js. See [the native target](native.md)
for what works today.

1. **Native core** (done): integers, booleans, strings, functions, control
   flow, modules. The runtime is written in Onyx.
2. **Heap types** (done): structs, lists and maps, with reference counting
   instead of a garbage collector.
3. **An optimising code generator** (done): variables in registers, no
   division instruction for constants, strings that grow in place, buffered
   output. Native programs now run faster than the JavaScript ones on most
   [benchmarks](../benchmarks/README.md), in a fraction of the memory.
4. **Error handling** (done): `!`, `fail`, `?`, `or` and `catch`, without
   exceptions.
5. **Strings** (done): every string method, indexing and loops over
   characters, counted in characters rather than bytes.
6. **Floats** (done): arithmetic in the SSE registers, exact reading and
   writing of decimal numbers, `pow`, all written without a C library.
7. **Lambdas and closures** (done), with `map`, `filter` and `sort_by`.
8. **The rest of the language** on the native target: files, `fork` and
   channels.
9. **Self-hosting**: the compiler rewritten in Onyx.

## Later

- **JVM backend** for Minecraft plugins (memory handled by the JVM), with an
  `OnyxLoader` plugin for Paper servers that loads `.ox` scripts directly.
- **Web**: run `.ox` files in the browser, DOM bindings, an online playground.
- **A game library** (`onyx.game`).
- More systems for the native target: ARM64, Windows, macOS.

## Language features under consideration

- Enums and `match`
- Generic functions and structs
- Optional values (`T?`)
- Named arguments
- A formatter (`onyx fmt`) and an editor extension with syntax highlighting

## Known limitations of v0.1

These concern the JavaScript target; see [native.md](native.md) for the native one.

- `int` is a JavaScript number: exact up to 2^53, not a 64-bit integer.
- Tasks started with `fork` take turns on a single thread (like `async` in
  JavaScript). They run in parallel while waiting on I/O or `sleep`, not while
  computing.
- Run-time panics do not show the Onyx line number yet.
- Characters outside the Basic Multilingual Plane (most emoji) count as two
  in `len`, `s[i]` and `slice`.
