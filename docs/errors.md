# Error codes

Every problem the compiler reports has a code, such as `E0200`. The
explanations below are also what `onyx explain E0200` prints.

## E0001

The source file contains a character that is not part of the Onyx language.

## E0002

A string literal or block comment was opened but never closed.

Strings start and end with a double quote: "hello".
To write a literal `{` inside a string, escape it: "\{".

## E0003

The parser found a token it did not expect. Check for a missing brace,
parenthesis, comma or type annotation near the reported location.

## E0100

A name was used that is not defined in the current scope.

Variables must be declared with `var` or `const` before they are used,
and functions must exist at the top level of the file.

## E0101

A type name was used that does not exist.

Built-in types are: `int`, `float`, `bool`, `string`, `void`, `error`, `[T]`,
`map<K, V>`, `chan<T>` and `fn(A) -> R`. Other types must be declared with `struct` or `interface`.

## E0102

An expression has a different type from the one required.

Onyx is statically typed: every value has one type, known at compile time.
The only implicit conversion is int -> float. Use int(x), float(x) or str(x)
to convert explicitly.

    var n: int = "hello"      // error
    var n: int = parse_int("42") or 0   // ok

## E0103

The same name was defined twice in one scope.

## E0104

A function was called with the wrong number of arguments.

## E0105

Only functions and methods can be called.

## E0106

The field or method does not exist on this type.

## E0107

An operator was applied to types it does not support.

Arithmetic works on int and float, `+` also joins two strings,
`&&`, `||` and `!` work on bool. To build a string from other values,
use interpolation: "score: {n}".

## E0108

A `const` binding (or a loop variable) cannot be reassigned.
Declare it with `var` if it needs to change.

## E0109

A function with a return type must return a value on every path.

## E0110

The compiler could not infer a type, usually for an empty list `[]` or
an empty map `{}`. Add a type annotation:

    var names: [string] = []

## E0111

`break` and `continue` can only be used inside a `while` or `for` loop.

## E0112

A struct literal must give a value to every field, exactly once,
and cannot mention fields that do not exist.

## E0113

Map keys must be of type int, string or bool.

## E0114

`for ... in` works on lists, strings, maps (keys), channels and ranges (a..b).

## E0115

Only lists, maps and strings can be indexed with `[...]`.

## E0116

A program needs an entry point:

    fn main() {
        print("hello")
    }

## E0117

`return` cannot be used here (for example inside a `fork` block,
which runs as a separate task).

## E0118

A top-level variable was used before its value was computed.

Top-level variables are initialised one after the other, from top to bottom,
and the variables of an imported file are initialised before those of the file
that imports it. An initialiser may call functions; if one of them uses a
variable that comes later, it would see garbage, so the compiler refuses.

    var total = compute()     // error: `compute` uses `base`...
    var base = 10             // ...which only gets its value here

    fn compute() -> int {
        return base * 2
    }

Move `base` above `total`, or compute `total` inside a function.

When two files import each other, the one that is run decides which file's
variables come first. Keeping initialisers free of calls into the other file
avoids the problem altogether.

The compiler follows every call that could happen, including calls through
interfaces and function values, so it may refuse a program that would have
worked. Reordering the declarations always fixes it.

## E0119

A `match` must say what happens for every value its subject can have.

For an enum, that is one case per variant, or an `else` for the rest:

    match shape {
        Circle(r) {
            print(r)
        }
        else {
            print("something else")
        }
    }

Numbers and strings have too many values to list: there an `else` is
always needed.

## E0200

A function whose return type ends with `!` can fail. Onyx does not let you
ignore that: every call must say what happens on failure.

    var data = read_file("a.txt")?              // pass the error to my caller
    var data = read_file("a.txt") or ""         // use a default value
    var data = read_file("a.txt") catch err {   // handle it here
        print("oops: {err}")
        return
    }

## E0201

`?` passes an error up to the caller, so it can only be used inside a
function that can itself fail (its return type ends with `!`).

    fn load() -> string! {
        return read_file("a.txt")?
    }

## E0202

`?`, `or` and `catch` handle the error of a call that can fail.
Here the expression can never fail, so there is nothing to handle.

Note that `or` has the lowest precedence; use parentheses when mixing it
with other operators: 1 + (parse_int(s) or 0)

## E0203

`fail` reports an error to the caller, so it can only be used inside a
function whose return type ends with `!`.

## E0204

When a `catch` block is used to produce a value, it must either leave
(return, fail, break, continue) or end with an expression of the right type.

## E0205

`catch` blocks may contain statements such as `return`, so they are only
allowed directly in a `var`, an assignment, a `return` or as a statement.
Use `or` inside larger expressions.

## E0206

The `!` marker is only valid on a function's return type.

## E0300

`<-` sends to and receives from channels only.

## E0400

An `import` names a file that does not exist or cannot be read.

Import paths are relative to the file that contains the import, and the
`.ox` extension is optional:

    import "utils"            // ./utils.ox
    import "lib/geometry"     // ./lib/geometry.ox

## E0401

A module was asked for something it does not define, or for a private
name. After `import "utils"`, the functions, variables and types of
utils.ox are used as `utils.name`. Names starting with `_` stay private to
their file.

## E0402

Every import needs a distinct, valid name. By default it is the file name;
choose another one with `as`:

    import "lib/string-utils" as strings

## E0500

The native target (`--target native`) builds a real Linux executable
without any other tool, but it does not support the whole language yet.
The same program runs on the JavaScript target with `onyx run`.
