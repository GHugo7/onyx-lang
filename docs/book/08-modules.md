# 8. Modules

A program can be split across several files. Each file is a module.

## Importing a file

`import` takes the path of another `.ox` file, relative to the file that
contains the import. The extension is optional.

`utils.ox`:

```onyx
const GREETING = "Hello"

struct User {
    name: string
}

fn greet(u: User) -> string {
    return "{GREETING}, {u.name}!"
}
```

`main.ox`:

```onyx
import "utils"

fn main() {
    var u = utils.User{name: "Ada"}
    print(utils.greet(u))
    print(utils.GREETING)
}
```

```bash
onyx run main.ox
```

Everything a module declares at its top level (functions, structs, interfaces,
`var` and `const`) is reached through the module name: `utils.greet`,
`utils.User`. Two modules can therefore use the same names without clashing.

## Choosing the name

By default the module is named after its file. Use `as` to pick another name,
which is required when the file name is not a valid identifier.

```onyx
import "lib/geometry" as geo
import "lib/string-utils" as strings

fn main() {
    var p: geo.Point = geo.origin()
    print(strings.shout("done"), p)
}
```

## Private names

A name that starts with an underscore can only be used inside its own file.

```onyx
fn area(w: int, h: int) -> int {
    return _check(w) * _check(h)
}

fn _check(n: int) -> int {      // not visible from other files
    return max(0, n)
}
```

## Good to know

- Imports go at the top level of a file, usually first.
- A file is loaded once, however many times it is imported.
- Two files may import each other.
- Only the file given to `onyx run` needs a `main`. A `main` in an imported
  file is an ordinary function.
- `onyx test file.ox` runs the `check` blocks of that file only, not those of
  the files it imports.
- A local variable hides a module of the same name, so avoid calling a
  variable `utils` when you also import `utils`.

See [`examples/shop`](../../examples/shop) for a small program made of three
files.
