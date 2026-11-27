# Roadmap

## v0.1: the core (done)

- Lexer, parser and type checker with rustc-style diagnostics
- Structs with methods, structural interfaces, lambdas and closures
- Lists, maps, strings, ranges
- Error handling with `!`, `?`, `or`, `catch`, `fail`
- `fork` and channels
- `check` blocks and `onyx test`
- Enums and `match`, weak references
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
8. **Files and input** (done): files, arguments, environment, keyboard and
   clock, through system calls.
9. **Tasks and channels** (done): `fork`, channels and `sleep`, with a
   scheduler written in Onyx. The native target now covers the whole
   language, except `fetch`.
10. **Self-hosting** (done): the compiler rewritten in Onyx, stage by
    stage. It compiles itself, into the very same executable as the Rust
    compiler makes of it. See [the compiler in Onyx](selfhost.md).
11. **The `onyx` command in Onyx** (done): `run`, `build`, `check`,
    `test`, `explain`, both targets, errors shown with their source. It
    behaves exactly like the one written in Rust, and replaces it.

From here on, the compiler written in Onyx is the reference: the one
written in Rust is frozen, and only builds the first Onyx compiler.

## In progress: the JVM target, towards Minecraft

See [the JVM target](jvm.md).

1. **The JVM target** (done): `--target jvm` writes a `.jar`, class files
   and archive included, with the runtime written in Onyx. The whole
   language works, tasks included, except `fetch`; the compiler itself runs
   on the JVM and compiles itself into the same `.jar`.
2. **The door to Java**: declaring Java classes and calling them, typed.
3. **Minecraft plugins**: a `.jar` per program that Paper loads, and a
   typed `minecraft` module (events, commands, players, worlds) that keeps
   track of what a plugin registered.
4. **OnyxLoader**: a Paper plugin that compiles the `.ox` files of a folder
   on the server, reloads them all or none, and keeps what it compiled.

## Later

- **Web**: run `.ox` files in the browser, DOM bindings, an online playground.
- **A game library** (`onyx.game`).
- More systems for the native target: ARM64, Windows, macOS.

## To do

- **`fetch` on the native target, with HTTPS.** `fetch` only exists on the
  JavaScript target today. Natively it means opening sockets, looking up
  names (DNS) and, for HTTPS, an implementation of TLS written in Onyx.

## Language features under consideration

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
