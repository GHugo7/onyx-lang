# The JVM target

`--target jvm` makes the Onyx compiler write a `.jar` file, which Java runs.
The compiler writes the class files and the archive by itself; no Java
compiler or build tool is involved. It is the first step towards Minecraft:
plugins for Paper servers, then `OnyxLoader`, which will load `.ox` files
on a running server.

```bash
onyx run --target jvm hello.ox
```

```bash
onyx build --target jvm hello.ox
```

```bash
java -jar build/hello.jar
```

The target only exists in [the compiler written in Onyx](selfhost.md): the
one written in Rust is frozen, and now only serves to build the first Onyx
compiler. Running a `.jar` needs Java 11 or newer.

## Status: experimental, but complete

The whole language works, `fork` and channels included; only `fetch` is
left out (rejected with error `E0500`, as on the native target). What was
checked:

- every program of `tests/run` and `tests/native` prints its expected output,
  and `onyx test --target jvm` reports the checks exactly as the other
  targets do;
- 800 programs written by the fuzzer print the same lines, the same errors
  and end with the same exit code as on the JavaScript target;
- 1000 generated programs with tasks and channels take turns in exactly the
  order of the native target (same output, same deadlocks, same panics);
- the compiler itself, compiled to a `.jar` (700 KB), runs on the JVM: it
  compiles its own source into the very same `.jar`, and into the very same
  native executable, byte for byte, as the native compiler does.

`cargo test` checks the first and the last point whenever `java` is
installed.

## How an Onyx program looks on the JVM

| Onyx | JVM |
| --- | --- |
| `int`, `float`, `bool` | `long`, `double`, `boolean` |
| `string` | `java.lang.String` |
| `[T]` | `java.util.ArrayList`, numbers boxed (`Long`, `Double`, `Boolean`) |
| `map<K, V>` | an object of the runtime that keeps the order of the keys |
| a top-level function | a static method of `onyx.Main` |
| a top-level variable | a static field of `onyx.Main` |
| a struct | a class `onyx.S$Name`, a method per method |
| an interface | a Java interface `onyx.I$Name`, implemented by every struct that has its methods |
| an enum | a class `onyx.E$Name`: which variant, and what it carries |
| a lambda | a class `onyx.L$id` holding what it captured |
| an error | an exception, `onyx.Failure`, thrown by `fail`, caught by `or` and `catch` |
| a bug (`panic`, division by zero, bad index...) | another exception, which ends the program |

Memory belongs to the JVM's garbage collector: there is no reference
counting here, and cycles are no problem. A weak reference simply holds its
object, as on the JavaScript target.

`main` runs on a thread with a stack of 512 MB, so deep recursion works as on
the native target. A recursion without end is reported as
`panic: stack overflow (infinite recursion?)`.

## The runtime, written in Onyx

What a program needs beyond a few instructions (printing, maps, the methods
of strings and lists, files, the scheduler of tasks...) is written in Onyx,
in `compiler/jvm/runtime.ox`, and compiled with the program. Only the
functions a program uses end up in its `.jar`: a hello world is a 6 KB file.

The runtime reaches Java through `__jvm`, a built-in function that only it
may use:

```onyx
fn __jrt_ord(s: string) -> int {
    if s.len() == 0 {
        panic("ord of an empty string")
    }
    return __jvm("virtual java/lang/String.codePointAt(I)I", s, 0)
}
```

The first argument says what to do: call a method (`static`, `virtual`,
`interface`), make an object (`new`), read a static field (`get`), test a
class (`is`). `__object` is the type of any Java object. A `!` after the
kind (`"static! ..."`) turns what Java throws into an Onyx error, which
`catch` can handle.

## Errors as exceptions

The JVM has exceptions, and they cost nothing until one is thrown: `fail`
throws `onyx.Failure` (without a stack trace, which nobody reads), `?` lets
it go up, and `or` and `catch` are regions of code whose `onyx.Failure`
goes to their handler. When the JVM catches an exception, it empties the
operand stack; so the compiler first moves every `or` to the start of a
statement (`lower.ox`), where nothing is pending on the stack.

## Tasks

Each task runs on a Java thread of its own (a virtual thread from Java 21
on), but only the one whose turn it is runs: the others are parked. The
scheduler is the one of the native target, written again in Onyx in the
runtime, so that tasks take turns in the same order on every target.

## Performance

The [benchmarks](../benchmarks/README.md), best of three runs, startup of
the JVM (about 50 ms) included:

| Program | Native | Node | JVM |
| --- | ---: | ---: | ---: |
| `alloc` | 163 ms | 173 ms | 203 ms |
| `closures` | 26 ms | 451 ms | 171 ms |
| `collatz` | 384 ms | 1488 ms | 334 ms |
| `fib` | 250 ms | 386 ms | 195 ms |
| `loops` | 203 ms | 305 ms | 302 ms |
| `maps` | 242 ms | 445 ms | 408 ms |
| `nbody` | 19 ms | 57 ms | 72 ms |
| `print` | 15 ms | 535 ms | 158 ms |
| `shapes` | 25 ms | 437 ms | 66 ms |
| `sieve` | 130 ms | 391 ms | 303 ms |
| `sort` | 136 ms | 353 ms | 520 ms |
| `strings` | 18 ms | 54 ms | 515 ms |
| `structs` | 17 ms | 47 ms | 73 ms |
| `tasks` | 13 ms | 85 ms | 1525 ms |

Once the JVM has compiled the hot code, plain computation is as fast as
native code, sometimes faster (`fib`, `collatz`). The Onyx compiler, run on
the JVM, compiles itself in about a second (a quarter of a second natively).

## Known gaps

- Building a long string with `+=` in a loop takes time that grows with the
  square of its length: Java strings cannot grow, every `+=` copies. (The
  native target grows a string in place; JavaScript uses ropes.) Collect the
  pieces in a list and `join` them instead.
- Passing the turn from a task to another wakes a thread up: a few
  microseconds, against a few nanoseconds natively. Programs that send
  hundreds of thousands of messages are slow (`tasks` above).
- Programs whose result depends on time (two `sleep`s a millisecond apart)
  may take turns differently: the first run of a piece of code is slower on
  the JVM, before it is compiled.
- Positions in strings count UTF-16 units, as on the JavaScript target:
  characters outside the Basic Multilingual Plane (most emoji) count as two.
- `run_program` takes an exit code above 128 for a program stopped by a
  signal (Java gives 128 + n), and returns -n as the other targets do.

## How it is made

| File | What |
| --- | --- |
| `compiler/classfile.ox` | Class files: the constant pool, the fields, the methods, the bytecode, the maximum depth of the stack |
| `compiler/jar.ox` | The `.jar` archive (ZIP, with its CRC-32) |
| `compiler/jvm.ox` | The code generator |
| `compiler/jvm/runtime.ox` | The runtime, in Onyx |

The classes are of version 49 (Java 5), which every JVM of today still runs:
from version 50 on, a method must describe the types of everything at each
jump target ("stack maps"), and with version 49 the JVM works them out
itself when it loads the class.

## Next

1. **The door to Java**: declaring Java classes and calling them from Onyx
   programs, as the runtime does with `__jvm`, but typed.
2. **Minecraft plugins**: a `.jar` per program that Paper loads, with a typed
   `minecraft` module (events, commands, players, worlds) that keeps track of
   what a plugin registered.
3. **OnyxLoader**: a plugin that compiles the `.ox` files of a folder on the
   server itself (the compiler already runs on the JVM), reloads them all or
   none, and keeps what it compiled.
