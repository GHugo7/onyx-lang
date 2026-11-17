# Standard library reference

Everything here is available without an import. A `!` after a return type
means the call can fail and must be handled with `?`, `or` or `catch`.

## Output and input

| Function | Description |
| --- | --- |
| `print(values...)` | Prints the values separated by spaces, then a new line |
| `input(prompt: string) -> string` | Reads one line from the keyboard |
| `args() -> [string]` | Command-line arguments |
| `env(name: string) -> string!` | Reads an environment variable |
| `exit(code: int)` | Ends the program |

## Conversions

| Function | Description |
| --- | --- |
| `str(value) -> string` | Text form of any value |
| `int(x: float) -> int` | Drops the decimals |
| `float(x: int) -> float` | |
| `parse_int(s: string) -> int!` | Fails when `s` is not a whole number |
| `parse_float(s: string) -> float!` | Fails when `s` is not a number |

## Bits and bytes

| Operation | Description |
| --- | --- |
| `a & b`, `a \| b`, `a ^ b` | Bit by bit: and, or, exclusive or |
| `~a` | Every bit flipped |
| `a << n`, `a >> n` | Bits moved left or right by `n` places (`>>` keeps the sign) |
| `ord(s: string) -> int` | The number of the first character: `ord("A")` is 65 |
| `chr(n: int) -> string` | The character with that number |
| `bytes(s: string) -> [int]` | The bytes of the string (UTF-8) |
| `from_bytes(data: [int]) -> string` | The string made of these bytes |
| `float_bits(x: float) -> int`, `float_from_bits(n: int) -> float` | The 64 bits of a float (IEEE 754), and back |
| `read_bytes(path: string) -> [int]!` | The bytes of a file |
| `write_bytes(path: string, data: [int]) -> void!` | Writes one byte per number |

An `int` has 64 bits. `&`, `<<` and `>>` bind like `*`; `|` and `^` like
`+`: `a | 1 << 4` is `a | (1 << 4)`, and comparisons come after all of them.
The operators are also functions: `bit_and`, `bit_or`, `bit_xor`, `bit_not`,
`shift_left`, `shift_right`.

## Math

| Function | Description |
| --- | --- |
| `abs(x)`, `min(a, b)`, `max(a, b)` | Work on `int` and `float` |
| `sqrt(x: float) -> float`, `pow(base: float, exp: float) -> float` | |
| `floor(x: float) -> int`, `ceil(x: float) -> int`, `round(x: float) -> int` | |
| `random() -> float` | Between 0 (included) and 1 (excluded) |
| `random_int(lo: int, hi: int) -> int` | Between `lo` and `hi`, both included |

## Files and network

| Function | Description |
| --- | --- |
| `read_file(path: string) -> string!` | |
| `write_file(path: string, text: string) -> void!` | Replaces the file |
| `append_file(path: string, text: string) -> void!` | |
| `file_exists(path: string) -> bool` | |
| `fetch(url: string) -> string!` | HTTP GET; fails on network errors and non-2xx statuses |

## Files read when compiling

| Function | Description |
| --- | --- |
| `embed(path: string) -> string` | The text of a file, read when the program is compiled |

`embed("data/words.txt")` is replaced by the text of the file, as if it had
been written in the program as a string. The path is relative to the file
that contains `embed`, like an import, and must be written as a plain string.
The program does not need the file any more when it runs: an executable made
with `onyx build` carries the text in it.

```onyx
const HELP = embed("help.txt")

fn main() {
    print(HELP)
}
```

## Time

| Function | Description |
| --- | --- |
| `now() -> int` | Milliseconds since 1970 |
| `sleep(ms: int)` | Pauses the current task |

## Checks

| Function | Description |
| --- | --- |
| `expect(condition: bool)` | Fails the current `check` when false |
| `panic(message: string)` | Stops the program: a bug was detected |

## string

| Method | Description |
| --- | --- |
| `len() -> int` | |
| `upper()`, `lower()`, `trim() -> string` | |
| `contains(s)`, `starts_with(s)`, `ends_with(s) -> bool` | |
| `index_of(s: string) -> int` | Position of `s`, or -1 |
| `slice(from: int, to: int) -> string` | `to` is excluded |
| `replace(old: string, new: string) -> string` | Replaces every occurrence |
| `split(separator: string) -> [string]` | |
| `chars() -> [string]` | |
| `repeat(n: int) -> string` | |
| `s[i]` | The character at position `i` |
| `for c in s { }` | Goes through the characters |

Positions and lengths count characters, not bytes: `"été".len()` is 3.

## [T] (list)

| Method | Description |
| --- | --- |
| `len() -> int` | |
| `push(value: T)` | Adds at the end |
| `pop() -> T!` | Removes and returns the last element; fails when empty |
| `first() -> T!`, `last() -> T!` | Fail when empty |
| `insert(index: int, value: T)`, `remove(index: int) -> T` | |
| `clear()` | |
| `contains(value: T) -> bool`, `index_of(value: T) -> int` | |
| `slice(from: int, to: int) -> [T]` | A copy; `to` is excluded |
| `reverse() -> [T]`, `sort() -> [T]` | Return a new list; `sort` needs `int`, `float` or `string` |
| `sort_by(key: fn(T) -> K) -> [T]` | Sorts by a computed `int`, `float` or `string` |
| `map(f: fn(T) -> U) -> [U]` | |
| `filter(f: fn(T) -> bool) -> [T]` | |
| `join(separator: string) -> string` | |

## map<K, V>

| Method | Description |
| --- | --- |
| `len() -> int` | |
| `m[key]` | The value; panics when missing |
| `get(key: K) -> V!` | The value; fails when missing |
| `has(key: K) -> bool` | |
| `remove(key: K)`, `clear()` | |
| `keys() -> [K]`, `values() -> [V]` | In insertion order |

## weak<T>

A reference that does not keep its object (a struct, a list, a map) alive.
See [the native target](native.md#memory).

| Operation | Description |
| --- | --- |
| `weak(object)` | A weak reference to `object` |
| `weak()` | An empty one; its type comes from where it is used |
| `get() -> T!` | The object; fails when it is gone |

## chan<T>

| Operation | Description |
| --- | --- |
| `chan<T>()`, `chan<T>(capacity)` | Creates a channel |
| `ch <- value` | Sends |
| `<-ch` | Receives |
| `close()` | No more values will be sent |
| `for v in ch { }` | Receives until the channel is closed |

## error

The value given to a `catch` block. `err.message` is its text.
