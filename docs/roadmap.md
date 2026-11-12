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

## Next

1. **JVM backend.** `onyx build --target jvm` producing a `.jar`, with `fork`
   mapped to real threads.
2. **Java interop and Minecraft.** Use Java classes from Onyx, then an
   `OnyxLoader` plugin for Paper servers that loads `.ox` scripts directly.
3. **Web.** Run `.ox` files in the browser, DOM bindings, an online playground.
4. **A game library** (`onyx.game`) shared by the web and desktop targets.

## Language features under consideration

- Enums and `match`
- Generic functions and structs
- Optional values (`T?`)
- Named arguments
- A formatter (`onyx fmt`) and an editor extension with syntax highlighting

## Known limitations of v0.1

- `int` is a JavaScript number: exact up to 2^53, not a 64-bit integer.
- A float that holds a whole number prints as `2.0` on its own, but as `2`
  inside a list, map or struct.
- Tasks started with `fork` take turns on a single thread (like `async` in
  JavaScript). They run in parallel while waiting on I/O or `sleep`, not while
  computing.
- Run-time panics do not show the Onyx line number yet.
