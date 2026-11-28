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

The whole language works: `fork`, channels and `fetch` (HTTP and HTTPS)
included. What was checked:

- every program of `tests/run` and `tests/native` prints its expected output,
  and `onyx test --target jvm` reports the checks exactly as the other
  targets do;
- 1600 programs written by the fuzzer print the same lines, the same errors
  and end with the same exit code as on the JavaScript target;
- 1000 generated programs with tasks and channels take turns in exactly the
  order of the native target (same output, same deadlocks, same panics),
  whichever of the three ways of passing the turn is used (see "Tasks");
- the compiler itself, compiled to a `.jar` (700 KB), runs on the JVM: it
  compiles its own source into the very same `.jar`, and into the very same
  native executable, byte for byte, as the native compiler does.

`cargo test` checks the first and the last point whenever `java` is
installed.

## How an Onyx program looks on the JVM

| Onyx | JVM |
| --- | --- |
| `int`, `float`, `bool` | `long`, `double`, `boolean` |
| `string` | `java.lang.String`, its positions counted in characters |
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

## Strings

A Java string is made of UTF-16 units, and a character above U+FFFF (most
emoji) takes two of them. Positions and lengths (`len`, `s[i]`, `slice`,
`index_of`) still count characters, as on the native target, and strings
compare by their characters. Most strings hold no such character, which
Java tells at once for a string whose characters are all among the first
256; the runtime also remembers the last string it looked at, so a loop
that goes through a string with `s[i]` finds each character from the one
before, in a time that does not grow with the position.

A Java string cannot grow either: each `s += piece` copies the whole of `s`.
So a local string variable that a loop only adds to is built in a
`java.lang.StringBuilder` while the loop runs, and gets its value back when
the loop ends:

```onyx
fn main() {
    var out = ""
    for i in 0..20000 {
        if out != "" {
            out += ", "
        }
        out += "item {i}"
    }
    print(out.len())
}
```

The loop may still ask for the length of the string and whether it is empty.
When it uses the string in any other way (`out.ends_with(",")`), every `+=`
in it copies again.

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

The scheduler is the one of the native target, written again in Onyx in the
runtime, so that tasks take turns in the same order on every target. How a
task is put aside and taken up again depends on the JVM:

1. With Java 21 and later, every task is a continuation of the JVM: a stack
   of its own that the JVM puts aside and gives back, all of them on the one
   thread of the program. Passing the turn takes a fifth of a microsecond.
   Continuations belong to the JVM's insides (`jdk.internal.vm`): the
   manifest of a `.jar` that uses `fork` asks for them, which `java -jar`
   grants.
2. Otherwise with Java 21 and later (`java -cp program.jar onyx.Main`), a
   virtual thread per task, all of them on one carrier thread: about twice
   as slow.
3. With older versions of Java, a thread of the system per task, of which
   only the one whose turn it is runs: passing the turn wakes a thread up, a
   matter of microseconds.

Before the program starts, the JVM is made to prepare what the first task,
the first continuation and the first `sleep` need, and every class of the
program is loaded: that work would otherwise delay the first turns. Sleepers
wake up in the order of their times in nanoseconds. So a program whose
result depends on time (two `sleep`s a millisecond apart) behaves as on the
native target; like there, it may still change on a busy machine.

`fetch` lets the other tasks run while the answer comes, as on the
JavaScript target.

## Performance

The [benchmarks](../benchmarks/README.md), best of three runs, startup of
the JVM (about 50 ms) included:

| Program | Native | Node | JVM |
| --- | ---: | ---: | ---: |
| `alloc` | 166 ms | 161 ms | 245 ms |
| `closures` | 27 ms | 360 ms | 182 ms |
| `collatz` | 414 ms | 1632 ms | 369 ms |
| `fib` | 292 ms | 456 ms | 229 ms |
| `loops` | 266 ms | 346 ms | 315 ms |
| `maps` | 177 ms | 381 ms | 407 ms |
| `nbody` | 21 ms | 85 ms | 65 ms |
| `print` | 21 ms | 919 ms | 160 ms |
| `shapes` | 26 ms | 516 ms | 64 ms |
| `sieve` | 99 ms | 272 ms | 265 ms |
| `sort` | 196 ms | 638 ms | 459 ms |
| `strings` | 19 ms | 54 ms | 120 ms |
| `structs` | 17 ms | 59 ms | 76 ms |
| `tasks` | 16 ms | 86 ms | 258 ms |

Once the JVM has compiled the hot code, plain computation is as fast as
native code, sometimes faster (`fib`, `collatz`). The Onyx compiler, run on
the JVM, compiles itself in about a second (a quarter of a second natively).

## Known gaps

- `run_program` takes an exit code above 128 for a program stopped by a
  signal, and returns -n as the other targets do. Java itself mixes the two
  up: it gives 128 + n for a program stopped by the signal n.
- When `fetch` fails before getting an answer (no network, a host that does
  not exist), its error says so in the JVM's words, which are not those of
  Node.js.

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
